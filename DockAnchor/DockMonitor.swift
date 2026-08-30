//
//  DockMonitor.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Foundation
import Cocoa
import ApplicationServices
import Carbon
import CoreGraphics
import Combine
import IOKit


private final class DisplayConfigurationCallbackContext {
    private let lock = NSLock()
    private weak var monitor: DockMonitor?

    init(monitor: DockMonitor) {
        self.monitor = monitor
    }

    func handle(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        lock.lock()
        let monitor = monitor
        lock.unlock()
        monitor?.handleDisplayConfigurationChange(
            displayID: displayID,
            flags: flags
        )
    }

    func invalidate() {
        lock.lock()
        monitor = nil
        lock.unlock()
    }
}

private func dockAnchorDisplayReconfigurationCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let context = Unmanaged<DisplayConfigurationCallbackContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    context.handle(displayID: displayID, flags: flags)
}

class DockMonitor: NSObject, ObservableObject {
    static let shared = DockMonitor()

    @Published var isActive = false
    @Published var anchoredDisplay: String = "Primary"
    @Published private(set) var statusMessage = "Dock Anchor Ready"
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var needsPermissionReset = false
    @Published private(set) var anchorIdentityState: AnchorIdentityState = .unavailable

    private(set) var reconciliationSnapshot = DisplayReconciliationSnapshot.empty
    private var identityRegistry = DockMonitor.loadIdentityRegistry()
    private var inventoryProvider: DisplayInventoryPreparing!
    private var inventoryRefreshCoordinator: DisplayInventoryRefreshCoordinator<PreparedDisplayInventory>!
    private var committedInventoryGeneration: UInt64?
    private var launchRelocationRequested = false
    private var inventoryAnchorRequestsToSkip: [DisplayAnchorChangeRequest] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private var anchorDisplayUUID: String = ""  // Hardware UUID for stable anchor tracking
    private let dockOrientationPreferences: DockOrientationPreferenceController
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?
    private var displayConfigurationCallbackContext: DisplayConfigurationCallbackContext?

    /// Gets the current anchor display ID (derived from UUID)
    private var anchorDisplayID: CGDirectDisplayID {
        return availableDisplays.first { $0.uuid == anchorDisplayUUID }?.id ?? CGMainDisplayID()
    }

    /// Magic value to identify our synthetic events (so we don't block our own events)
    private let syntheticEventMarker: Int64 = 0xD0C4A5C4 // "DOCKASCR" in hex-ish

    private lazy var eventClassifier = EventTapClassifierStore(
        syntheticEventMarker: syntheticEventMarker
    )
    private lazy var statusMessages = StatusMessageCoordinator(
        initialMessage: statusMessage
    ) { [weak self] message in
        self?.statusMessage = message
    }
    private lazy var blockedEventFeedback = BlockedEventFeedbackController(
        scheduler: DispatchEventFeedbackScheduler(queue: .main),
        statusMessages: statusMessages
    ) { [weak self] in
        self?.defaultStatusMessage ?? "Dock Anchor Ready"
    }

    enum AnchorIdentityState: String {
        case unique
        case unavailable
        case ambiguous
        case unresolved
    }

    struct DisplayInfo: Identifiable, Hashable {
        let id: CGDirectDisplayID
        /// A persistent reconciled identity when unique, otherwise the current
        /// UUID/runtime reference used only for explicit selection.
        let uuid: String
        let serialNumber: UInt32?
        let frame: CGRect
        let name: String
        let isPrimary: Bool
        let isBuiltIn: Bool
        let identityResolution: DisplayPhysicalResolution

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(uuid)
            hasher.combine(frame.origin.x)
            hasher.combine(frame.origin.y)
            hasher.combine(frame.size.width)
            hasher.combine(frame.size.height)
        }

        static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
            lhs.id == rhs.id &&
            lhs.uuid == rhs.uuid &&
            lhs.frame == rhs.frame &&
            lhs.name == rhs.name &&
            lhs.identityResolution == rhs.identityResolution
        }
    }

    private var defaultStatusMessage: String {
        isActive
            ? "Dock Anchor Active - Monitoring mouse movement"
            : "Dock Anchor Ready"
    }

    /// All delayed status work is revision-checked through this coordinator.
    /// Most callers already execute on the main run loop; the fallback keeps
    /// @Published updates main-thread confined if a system callback does not.
    @discardableResult
    private func publishStatus(_ message: String) -> StatusMessageRevision {
        if Thread.isMainThread {
            return statusMessages.publish(message)
        }
        return DispatchQueue.main.sync {
            statusMessages.publish(message)
        }
    }

    private func rebuildEventClassifierConfiguration() {
        let plan = DockEdgePlanner.makePlan(
            orientation: dockOrientationPreferences.currentOrientation,
            displays: availableDisplays.map {
                DockEdgeDisplay(
                    displayID: UInt64($0.id),
                    frame: $0.frame
                )
            }
        )
        let names = Dictionary(
            uniqueKeysWithValues: availableDisplays.map {
                (UInt64($0.id), $0.name)
            }
        )
        eventClassifier.updateDockEdgePlan(
            plan,
            displayNames: names,
            anchorDisplayID: UInt64(anchorDisplayID)
        )
    }

    /// Re-reads the preference without treating a missing/malformed value as
    /// bottom. A valid transition publishes one complete topology plan while
    /// monitoring continues to use the existing event tap.
    @discardableResult
    private func refreshDockOrientation(
        rebuildGeometry: Bool = true,
        announceChange: Bool = true
    ) -> DockOrientationRefreshResult {
        let result = dockOrientationPreferences.refresh()
        if result.didChange, rebuildGeometry {
            rebuildEventClassifierConfiguration()
        }
        if result.didChange, announceChange, isMonitoring {
            publishStatus(
                "Dock orientation updated to \(result.currentOrientation.rawValue)"
            )
            resetStatusMessage(after: 2.0)
        }
        return result
    }

    /// Resolves persisted identity only. Explicit selection of a current
    /// ambiguous display goes through `changeAnchorDisplay`, never this lookup.
    func getDisplayID(forUUID uuid: String) -> CGDirectDisplayID? {
        if case let .resolved(runtimeID, _) = reconciliationSnapshot.resolve(
            uuid,
            excludingInferredReferences: AppSettings.shared.nonPersistentDisplayReferences
        ) {
            return CGDirectDisplayID(runtimeID)
        }
        return nil
    }

    func getDisplayUUID(forID displayID: CGDirectDisplayID) -> String? {
        availableDisplays.first { $0.id == displayID }?.uuid
    }

    func displayIdentityState(for reference: String) -> AnchorIdentityState {
        switch reconciliationSnapshot.resolve(
            reference,
            excludingInferredReferences: AppSettings.shared.nonPersistentDisplayReferences
        ) {
        case .resolved: return .unique
        case .unavailable: return .unavailable
        case .ambiguous: return .ambiguous
        case .unresolved: return .unresolved
        }
    }

    func isDisplayAvailable(uuid: String) -> Bool {
        displayIdentityState(for: uuid) == .unique
    }

    func getCurrentUUID(matching uuid: String) -> String? {
        if case let .resolved(_, canonicalReference) = reconciliationSnapshot.resolve(
            uuid,
            excludingInferredReferences: AppSettings.shared.nonPersistentDisplayReferences
        ) {
            return canonicalReference
        }
        return nil
    }

    override convenience init() {
        self.init(orientationProvider: SystemDockOrientationProvider())
    }

    init(
        orientationProvider: DockOrientationProviding,
        inventoryProvider suppliedInventoryProvider: DisplayInventoryPreparing? = nil,
        inventoryScheduler: DisplayInventoryRefreshScheduling = DispatchDisplayInventoryRefreshScheduler()
    ) {
        dockOrientationPreferences = DockOrientationPreferenceController(
            provider: orientationProvider
        )
        super.init()

        let provider = suppliedInventoryProvider
            ?? ReconciledDisplayInventoryProvider(
                source: SystemDisplayInventorySource(),
                initialRegistry: identityRegistry
            )
        inventoryProvider = provider
        let orientationPreferences = dockOrientationPreferences
        inventoryRefreshCoordinator = DisplayInventoryRefreshCoordinator(
            scheduler: inventoryScheduler,
            operation: { [provider, orientationPreferences] scope, cancellation in
                guard let prepared = provider.prepare(
                    scope: scope,
                    cancellation: cancellation
                ), !cancellation.isCancelled else { return nil }
                // Keep the existing defaults-based orientation provider, but
                // never execute it on the main queue as part of inventory
                // publication.
                _ = orientationPreferences.refresh()
                return cancellation.isCancelled ? nil : prepared
            },
            commit: { [weak self] prepared, request, generation in
                self?.commitInventory(
                    prepared,
                    request: request,
                    generation: generation
                )
            }
        )

        setupNotificationObservers()
        setupInitialState()
    }

    private func setupInitialState() {
        // Keep a cheap runtime reference only until the first complete
        // asynchronous inventory commits. No CoreGraphics/IOKit/profiler work
        // is performed synchronously during monitor initialization.
        anchorDisplayUUID = Self.getCurrentDisplayReference(for: CGMainDisplayID())
        inventoryRefreshCoordinator.request(
            .demand(reason: .initialization)
        )
        setupDisplayConfigurationMonitoring()
        _ = requestAccessibilityPermissions()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .anchorDisplayChanged)
            .compactMap { $0.object as? DisplayAnchorChangeRequest }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self = self else { return }
                if let index = self.inventoryAnchorRequestsToSkip.firstIndex(
                    of: request
                ) {
                    self.inventoryAnchorRequestsToSkip.remove(at: index)
                    return
                }
                let decision = self.applyAnchorReference(
                    request.reference,
                    intent: request.selectionIntent,
                    announceChange: true
                )
                self.resetStatusMessage(after: 3.0)

                // Both display clicks and profile activation use this one
                // ambiguity-aware result. In particular, a profile's ambiguous
                // UUID remains on the configured fallback and cannot relocate.
                if request.permitsAutomaticRelocation(
                    enabled: AppSettings.shared.autoRelocateDock,
                    decision: decision
                ) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.relocateDockToAnchoredDisplay()
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .defaultAnchorDisplayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // When default anchor setting changes and no profile is active,
                // update to the new default if the current display is unavailable
                guard let self = self else { return }
                if AppSettings.shared.activeProfileID == nil {
                    self.applyDefaultAnchorIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    /// Gets the UUID of the built-in display (if available)
    func getBuiltInDisplayUUID() -> String? {
        availableDisplays.first { $0.isBuiltIn }?.uuid
    }

    /// Gets the reconciled reference for the current main display.
    func getMainDisplayUUID() -> String {
        availableDisplays.first { $0.isPrimary }?.uuid
            ?? Self.getCurrentDisplayReference(for: CGMainDisplayID())
    }

    /// Gets the appropriate default anchor display UUID based on user settings
    func getDefaultAnchorDisplayUUID() -> String {
        switch AppSettings.shared.defaultAnchorDisplay {
        case .builtIn:
            // Try to use built-in display, fall back to main if not available
            return getBuiltInDisplayUUID() ?? getMainDisplayUUID()
        case .main:
            return getMainDisplayUUID()
        }
    }

    private func getDefaultAnchorDisplayID() -> CGDirectDisplayID? {
        if AppSettings.shared.defaultAnchorDisplay == .builtIn,
           let builtIn = availableDisplays.first(where: { $0.isBuiltIn }) {
            return builtIn.id
        }
        return availableDisplays.first(where: { $0.isPrimary })?.id
            ?? availableDisplays.first?.id
    }

    /// Re-evaluates the effective fallback without modifying the preferred
    /// anchor persisted by the user or active profile.
    private func applyDefaultAnchorIfNeeded() {
        validateCurrentAnchorDisplay()
        updateAnchoredDisplayName()
    }

    /// View appearance is demand, not an invalidation. A valid committed
    /// inventory or initialization already in flight is reused.
    func updateAvailableDisplays() {
        inventoryRefreshCoordinator.request(
            .demand(reason: .viewAppearance)
        )
    }

    private func requestInventoryInvalidation(
        scope: DisplayInventoryRefreshScope,
        reasons: DisplayInventoryRefreshReasons
    ) {
        inventoryRefreshCoordinator.request(
            .invalidation(scope: scope, reasons: reasons)
        )
    }

    /// Application launch can arrive before or after initialization finishes.
    /// In both cases it reuses that inventory and performs at most one
    /// generation-checked relocation after a complete snapshot exists.
    func requestLaunchInventory(automaticallyRelocate: Bool) {
        inventoryRefreshCoordinator.request(
            .demand(reason: .initialization)
        )
        guard automaticallyRelocate else { return }
        launchRelocationRequested = true
        if let generation = committedInventoryGeneration,
           inventoryRefreshCoordinator.isCurrentGeneration(generation) {
            launchRelocationRequested = false
            scheduleInventoryRelocation(after: 1.5, generation: generation)
        }
    }

    var inventoryRefreshDiagnostics: DisplayInventoryRefreshDiagnostics {
        inventoryRefreshCoordinator.diagnostics
    }

    private func commitInventory(
        _ prepared: PreparedDisplayInventory,
        request: DisplayInventoryRefreshRequest,
        generation: UInt64
    ) {
        let priorRuntimeIDs = Set(availableDisplays.map { UInt64($0.id) })
        var snapshot = prepared.reconciliation

        // Migration, registry history, and registry persistence are performed
        // once and only for the accepted generation.
        let selectedReferenceBeforeMigration = AppSettings.shared.selectedDisplayUUID
        let migrations = AppSettings.shared.reconcileDisplayReferences(
            using: snapshot
        )
        if AppSettings.shared.selectedDisplayUUID != selectedReferenceBeforeMigration {
            inventoryAnchorRequestsToSkip.append(DisplayAnchorChangeRequest(
                reference: AppSettings.shared.selectedDisplayUUID,
                selectionIntent: .persistedPreference,
                requestsAutomaticRelocation: false
            ))
        }
        let committedRegistry = snapshot.registry.recordingLegacyReferences(
            migrations
        )
        snapshot = snapshot.withRegistry(committedRegistry)
        let displays = makeDisplayInfos(
            from: prepared.acquisition,
            snapshot: snapshot
        )

        identityRegistry = committedRegistry
        reconciliationSnapshot = snapshot
        availableDisplays = displays
        inventoryProvider.recordCommittedInventory(
            prepared.acquisition,
            registry: committedRegistry
        )

        // Orientation, anchor resolution, classifier frames, and relocation
        // geometry all derive from this same accepted inventory before the one
        // public display-change notification is sent.
        _ = applyAnchorReference(
            AppSettings.shared.selectedDisplayUUID,
            intent: .persistedPreference,
            announceChange: false,
            rebuildGeometry: false
        )
        saveIdentityRegistry()
        committedInventoryGeneration = generation

        let currentRuntimeIDs = Set(displays.map { UInt64($0.id) })
        handleCommittedInventorySideEffects(
            request: request,
            generation: generation,
            addedRuntimeIDs: currentRuntimeIDs.subtracting(priorRuntimeIDs),
            removedRuntimeIDs: priorRuntimeIDs.subtracting(currentRuntimeIDs)
        )
        // Profile activation above may change the effective anchor. Publish
        // topology, anchor exclusion, and relocation geometry together once.
        rebuildEventClassifierConfiguration()

        NotificationCenter.default.post(name: .displaysDidChange, object: nil)
    }

    private func makeDisplayInfos(
        from acquisition: DisplayInventoryAcquisition,
        snapshot: DisplayReconciliationSnapshot
    ) -> [DisplayInfo] {
        let runtimes = acquisition.runtime.observations
        let aliasCounts = Dictionary(
            grouping: runtimes.compactMap(\.uuidAlias),
            by: { $0 }
        ).mapValues(\.count)
        let mainRuntimeID = acquisition.runtime.mainRuntimeID

        var displays = snapshot.displays.map { reconciled -> DisplayInfo in
            let runtimeID = reconciled.runtime.runtimeID
            let displayID = CGDirectDisplayID(runtimeID)
            let frame = acquisition.runtime.framesByRuntimeID[runtimeID] ?? .zero
            let isPrimary = runtimeID == mainRuntimeID
            let explicitReference: String
            if reconciled.resolution == .unique,
               let persistent = reconciled.persistentReference {
                explicitReference = persistent
            } else if let alias = reconciled.runtime.uuidAlias,
                      aliasCounts[alias] == 1 {
                explicitReference = alias
            } else {
                explicitReference = "DisplayID-\(displayID)"
            }

            let baseName = reconciled.friendlyName
                ?? fallbackDisplayName(
                    frame: frame,
                    mainFrame: acquisition.runtime.framesByRuntimeID[mainRuntimeID]
                        ?? .zero,
                    isPrimary: isPrimary,
                    isBuiltIn: reconciled.isBuiltIn
                )
            let name = isPrimary && !baseName.contains("(Primary)")
                ? "\(baseName) (Primary)"
                : baseName
            return DisplayInfo(
                id: displayID,
                uuid: explicitReference,
                serialNumber: reconciled.identity?.serialNumber,
                frame: frame,
                name: name,
                isPrimary: isPrimary,
                isBuiltIn: reconciled.isBuiltIn,
                identityResolution: reconciled.resolution
            )
        }

        displays.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        return displays
    }

    private func handleCommittedInventorySideEffects(
        request: DisplayInventoryRefreshRequest,
        generation: UInt64,
        addedRuntimeIDs: Set<UInt64>,
        removedRuntimeIDs: Set<UInt64>
    ) {
        let settings = AppSettings.shared
        var relocationDelay: TimeInterval?
        var statusResetDelay: TimeInterval?

        if request.reasons.contains(.displayAdded) && !addedRuntimeIDs.isEmpty {
            let decisions = addedRuntimeIDs.sorted().map { runtimeID in
                DisplayHotPlugResolver.displayAdded(
                    runtimeID: runtimeID,
                    preferredReference: settings.selectedDisplayUUID,
                    profileReferences: settings.profiles.map(\.anchorDisplayUUID),
                    profileAutoActivation: settings.profiles.map(\.autoActivate),
                    currentAnchorIsUnique: anchorIdentityState == .unique,
                    autoRelocate: settings.autoRelocateDock,
                    snapshot: reconciliationSnapshot,
                    excludingInferredReferences: settings.nonPersistentDisplayReferences
                )
            }
            let profileIndices = Set(
                decisions.compactMap(\.autoActivateProfileIndex)
            )
            var profileActivated = false
            if profileIndices.count == 1,
               let profileIndex = profileIndices.first,
               settings.profiles.indices.contains(profileIndex) {
                let profile = settings.profiles[profileIndex]
                let currentAnchorMatches =
                    settings.selectedDisplayUUID == profile.anchorDisplayUUID
                if settings.activeProfileID != profile.id || !currentAnchorMatches {
                    let resolution = settings.switchToProfile(
                        profile,
                        using: reconciliationSnapshot,
                        requestsAutomaticRelocation: false
                    )
                    inventoryAnchorRequestsToSkip.append(
                        DisplayAnchorChangeRequest(
                            reference: profile.anchorDisplayUUID,
                            selectionIntent: .persistedPreference,
                            requestsAutomaticRelocation: false
                        )
                    )
                    _ = applyAnchorReference(
                        profile.anchorDisplayUUID,
                        intent: .persistedPreference,
                        announceChange: false,
                        rebuildGeometry: false
                    )
                    publishStatus("Auto-activated profile: \(profile.name)")
                    profileActivated = true
                    if settings.autoRelocateDock,
                       resolution.isUniquelyResolved {
                        relocationDelay = 1.0
                    }
                }
            }

            if !profileActivated {
                if decisions.contains(where: \.restoresPreferredAnchor) {
                    publishStatus(
                        "Preferred display reconnected - restoring anchor to \(anchoredDisplay)"
                    )
                } else if decisions.contains(where: \.isAmbiguous) {
                    publishStatus(
                        "Ambiguous display identity - preserving the preferred anchor"
                    )
                } else {
                    publishStatus(
                        "New display detected - reconciled display identities"
                    )
                }
                if decisions.contains(where: \.permitsAutomaticRelocation) {
                    relocationDelay = 1.0
                }
            }
            statusResetDelay = 3.0
        }

        if request.reasons.contains(.displayRemoved) && !removedRuntimeIDs.isEmpty {
            if anchorIdentityState == .ambiguous {
                publishStatus(
                    "Ambiguous display identity - preserving the preferred anchor"
                )
            } else if anchorIdentityState != .unique {
                let defaultName = settings.defaultAnchorDisplay == .builtIn
                    ? "Built-in" : "Primary"
                publishStatus(
                    "Anchor display disconnected - temporarily using \(defaultName)"
                )
            } else {
                publishStatus("Display removed - reconciled display identities")
            }
            statusResetDelay = 3.0
        }

        if request.reasons.contains(.mainDisplayChanged) {
            publishStatus("Main display updated")
            if anchorIdentityState != .ambiguous,
               settings.autoRelocateDock {
                relocationDelay = min(relocationDelay ?? 0.5, 0.5)
            }
            statusResetDelay = 3.0
        } else if request.reasons.contains(.arrangementChanged) {
            publishStatus("Display arrangement updated")
            statusResetDelay = max(statusResetDelay ?? 0, 2.0)
        }

        if launchRelocationRequested {
            launchRelocationRequested = false
            if anchorIdentityState == .unique,
               settings.autoRelocateDock {
                relocationDelay = min(relocationDelay ?? 1.5, 1.5)
            }
        }

        if let relocationDelay {
            scheduleInventoryRelocation(
                after: relocationDelay,
                generation: generation
            )
        }
        if let statusResetDelay {
            resetStatusMessage(after: statusResetDelay)
        }
    }

    private func scheduleInventoryRelocation(
        after delay: TimeInterval,
        generation: UInt64
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.inventoryRefreshCoordinator.isCurrentGeneration(
                    generation
                  ) else { return }
            self.relocateDockToAnchoredDisplay()
        }
    }

    private func validateCurrentAnchorDisplay() {
        _ = applyAnchorReference(
            AppSettings.shared.selectedDisplayUUID,
            intent: .persistedPreference,
            announceChange: false
        )
    }

    /// Reapplies the saved value without granting it the privileges of an
    /// explicit click. This is the launch/view-appearance path: an ambiguous
    /// value uses fallback and does not permit automatic relocation.
    @discardableResult
    func restorePersistedAnchor() -> DisplayAnchorDecision {
        applyAnchorReference(
            AppSettings.shared.selectedDisplayUUID,
            intent: .persistedPreference,
            announceChange: false
        )
    }

    @discardableResult
    private func applyAnchorReference(
        _ reference: String,
        intent: DisplayAnchorSelectionIntent,
        announceChange: Bool,
        rebuildGeometry: Bool = true
    ) -> DisplayAnchorDecision {
        let decision = DisplayAnchorResolver.resolve(
            preferredReference: reference,
            fallbackRuntimeID: getDefaultAnchorDisplayID().map { UInt64($0) },
            snapshot: reconciliationSnapshot,
            intent: intent,
            excludingInferredReferences: AppSettings.shared.nonPersistentDisplayReferences
        )

        guard let runtimeID = decision.effectiveRuntimeID,
              let display = availableDisplays.first(where: {
                  $0.id == CGDirectDisplayID(runtimeID)
              }) else {
            useConfiguredFallback(
                state: identityState(for: decision.preferredResolution),
                rebuildGeometry: rebuildGeometry
            )
            return decision
        }

        anchorDisplayUUID = display.uuid
        updateAnchoredDisplayName()
        if decision.usesFallback {
            useConfiguredFallback(
                state: identityState(for: decision.preferredResolution),
                display: display,
                rebuildGeometry: rebuildGeometry
            )
        } else if decision.isTemporaryExplicitSelection {
            anchorIdentityState = .ambiguous
            if announceChange {
                publishStatus("Anchor changed to \(anchoredDisplay) (physical identity ambiguous)")
            }
        } else {
            anchorIdentityState = .unique
            if announceChange {
                publishStatus("Anchor changed to \(anchoredDisplay)")
            }
        }
        if rebuildGeometry {
            rebuildEventClassifierConfiguration()
        }
        return decision
    }

    private func identityState(for resolution: DisplayReferenceResolution) -> AnchorIdentityState {
        switch resolution {
        case .resolved: return .unique
        case .unavailable: return .unavailable
        case .ambiguous: return .ambiguous
        case .unresolved: return .unresolved
        }
    }

    private func useConfiguredFallback(
        state: AnchorIdentityState,
        display: DisplayInfo? = nil,
        rebuildGeometry: Bool = true
    ) {
        anchorIdentityState = state
        if let display = display
            ?? getDefaultAnchorDisplayID().flatMap({ defaultID in
                availableDisplays.first { $0.id == defaultID }
            }) {
            anchorDisplayUUID = display.uuid
        } else {
            anchorDisplayUUID = getDefaultAnchorDisplayUUID()
        }
        updateAnchoredDisplayName()
        let defaultName = AppSettings.shared.defaultAnchorDisplay == .builtIn ? "Built-in" : "Primary"
        switch state {
        case .ambiguous:
            publishStatus("Ambiguous display identity - temporarily using \(defaultName)")
        case .unavailable:
            publishStatus("Anchor display unavailable - temporarily using \(defaultName)")
        case .unresolved:
            publishStatus("Anchor display reference unresolved - temporarily using \(defaultName)")
        case .unique:
            break
        }
        if rebuildGeometry {
            rebuildEventClassifierConfiguration()
        }
    }

    private func updateAnchoredDisplayName() {
        if let display = availableDisplays.first(where: { $0.uuid == anchorDisplayUUID }) {
            anchoredDisplay = display.name
        }
    }

    /// An explicit UI/menu selection may temporarily target an ambiguous
    /// current display, but it never establishes a persistent alias.
    @discardableResult
    func changeAnchorDisplay(toUUID uuid: String) -> DisplayAnchorDecision {
        let decision = applyAnchorReference(
            uuid,
            intent: .explicitUserSelection,
            announceChange: true
        )
        resetStatusMessage(after: 3.0)
        return decision
    }

    func changeAnchorDisplay(to displayID: CGDirectDisplayID) {
        guard let uuid = getDisplayUUID(forID: displayID) else { return }
        changeAnchorDisplay(toUUID: uuid)
    }

    func requestAccessibilityPermissions() -> Bool {
        // Check if already trusted (without prompting)
        let trusted = AXIsProcessTrusted()

        if !trusted {
            DispatchQueue.main.async { [weak self] in
                self?.publishStatus("Accessibility permissions required")
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.needsPermissionReset = false
            }
        }

        return trusted
    }

    /// Prompts for accessibility permissions by opening System Preferences
    /// Note: On modern macOS, the system dialog often just opens System Preferences
    /// without actually adding the app - users must manually add it with the + button
    func promptForAccessibilityPermissions() {
        // Use the string key directly to avoid takeRetainedValue() issues
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Checks accessibility permissions without prompting
    private func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Opens System Preferences to the Accessibility pane
    func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts the timer that periodically checks if permissions are still valid
    private func startPermissionMonitoring() {
        // Check every 2 seconds for permission changes
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.verifyPermissionsAndTapValidity()
        }
    }

    /// Stops the permission monitoring timer
    private func stopPermissionMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Verifies that accessibility permissions are still granted and event tap is valid
    private func verifyPermissionsAndTapValidity() {
        guard isMonitoring else { return }

        // Polling the Dock preference while active applies left/right/bottom
        // transitions without rebuilding the event tap or restarting monitoring.
        _ = refreshDockOrientation()

        // Check if accessibility permissions are still granted
        if !checkAccessibilityPermissions() {
            DispatchQueue.main.async { [weak self] in
                self?.publishStatus("Accessibility permissions revoked - stopping monitoring")
                self?.stopMonitoring()
            }
            return
        }

        // Check if the event tap is still valid
        if let tap = eventTap, !CFMachPortIsValid(tap) {
            DispatchQueue.main.async { [weak self] in
                self?.publishStatus("Event tap invalidated - stopping monitoring")
                self?.stopMonitoring()
            }
            return
        }
    }

    func startMonitoring() {
        guard requestAccessibilityPermissions() else {
            publishStatus("Please grant accessibility permissions in System Preferences")
            return
        }

        guard !isMonitoring else { return }

        inventoryRefreshCoordinator.request(
            .demand(reason: .monitoringStartup)
        )

        // Include mouse moved + tap-disabled notifications so we can recover if the system disables tap
        let mouseMovedMask = 1 << CGEventType.mouseMoved.rawValue
        let disabledByTimeoutMask = 1 << CGEventType.tapDisabledByTimeout.rawValue
        let disabledByUserInputMask = 1 << CGEventType.tapDisabledByUserInput.rawValue
        let eventMask = CGEventMask(mouseMovedMask | disabledByTimeoutMask | disabledByUserInputMask)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                // Recover if the system disabled tap due to timeout or user input
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        DispatchQueue.main.async {
                            monitor.publishStatus("Recovered event tap after system disable")
                        }
                    }
                    // Pass the event through so the system continues to receive it
                    return Unmanaged.passUnretained(event)
                }

                return monitor.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            // Event tap creation failed even though permissions appeared granted.
            // This usually means the permission entry is stale (app was updated).
            // The user needs to remove and re-add the app in Accessibility settings.
            needsPermissionReset = true
            publishStatus("Permission needs reset - remove and re-add app in Accessibility settings")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        isMonitoring = true
        startPermissionMonitoring()
        DispatchQueue.main.async { [weak self] in
            self?.isActive = true
            self?.publishStatus("Dock Anchor Active - Monitoring mouse movement")
        }
    }

    func stopMonitoring() {
        stopPermissionMonitoring()
        guard isMonitoring else { return }

        isMonitoring = false
        blockedEventFeedback.cancelPendingFeedback()

        // Safely disable and clean up event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }

        // Safely remove run loop source
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.isActive = false
            self?.publishStatus("Dock Anchor Stopped")
        }
    }

    /// Creates a temporary event tap for dock relocation when monitoring isn't active
    /// Returns true if tap was successfully created
    private func createEventTapForRelocation() -> Bool {
        guard eventTap == nil else { return false }

        let mouseMovedMask = 1 << CGEventType.mouseMoved.rawValue
        let eventMask = CGEventMask(mouseMovedMask)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        return true
    }

    /// Removes the temporary event tap created for relocation
    private func removeTemporaryEventTap() {
        // Only remove if we're not in monitoring mode
        guard !isMonitoring else { return }

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    /// Moves the dock to the anchored display by simulating mouse movement to the dock trigger zone
    func relocateDockToAnchoredDisplay() {
        guard anchorIdentityState != .ambiguous else {
            publishStatus("Cannot relocate dock - display identity is ambiguous")
            return
        }
        guard let anchorDisplay = availableDisplays.first(where: { $0.id == anchorDisplayID }) else {
            publishStatus("Cannot relocate dock - anchor display not found")
            return
        }
        let relocationSelection = eventClassifier.relocationSelection(
            for: UInt64(anchorDisplay.id)
        )
        guard relocationSelection.result?.geometry != nil else {
            publishStatus(
                "Cannot relocate dock - no exposed \(relocationSelection.dockPosition.rawValue) edge on \(anchorDisplay.name)"
            )
            resetStatusMessage(after: 2.0)
            return
        }

        // Only relocate if we have multiple displays
        guard availableDisplays.count > 1 else {
            return
        }

        // Check if dock is already on the anchored display
        if let currentDockDisplay = getCurrentDockDisplayID(), currentDockDisplay == anchorDisplayID {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.publishStatus("Dock is already on \(anchorDisplay.name)")
                self.resetStatusMessage(after: 2.0)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.publishStatus("Relocating dock to \(anchorDisplay.name)...")
        }

        // Perform relocation on background thread to not block UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Save current mouse position
            let originalPosition = CGEvent(source: nil)?.location ?? .zero

            // Ensure event tap is active so we can intercept user mouse input
            // If monitoring wasn't started, we need to temporarily create the tap
            var temporaryTapCreated = false
            if self.eventTap == nil {
                temporaryTapCreated = self.createEventTapForRelocation()
            }

            // Eligibility and relocation suppression come from one current,
            // atomically published topology snapshot. A layout/orientation
            // change that removed the edge cannot lead to cursor movement.
            guard let relocation = self.eventClassifier.beginRelocation(
                for: UInt64(anchorDisplay.id)
            )?.geometry else {
                if temporaryTapCreated {
                    self.removeTemporaryEventTap()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.publishStatus(
                        "Cannot relocate dock - anchor has no eligible edge"
                    )
                    self.resetStatusMessage(after: 2.0)
                }
                return
            }

            // Hide cursor during the operation for better UX
            DispatchQueue.main.sync {
                NSCursor.hide()
            }

            // Create an event source for our synthetic events
            let eventSource = CGEventSource(stateID: .hidSystemState)
            let approachPoint = relocation.approachPoint
            let edgePoint = relocation.targetPoint

            // Warp to approach point first
            CGWarpMouseCursorPosition(approachPoint)
            Thread.sleep(forTimeInterval: 0.03)

            // Generate mouse move events toward the edge (this is what triggers dock movement)
            for i in 0..<8 {
                let progress = CGFloat(i) / 7.0
                let currentX = approachPoint.x + (edgePoint.x - approachPoint.x) * progress
                let currentY = approachPoint.y + (edgePoint.y - approachPoint.y) * progress
                let currentPoint = CGPoint(x: currentX, y: currentY)

                // Force cursor position and post event
                CGWarpMouseCursorPosition(currentPoint)
                if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: currentPoint, mouseButton: .left) {
                    // Mark as our synthetic event so our tap lets it through
                    moveEvent.setIntegerValueField(.eventSourceUserData, value: self.syntheticEventMarker)
                    moveEvent.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.015)
            }

            // Hold at edge with continued events - this is where stability matters most
            for _ in 0..<8 {
                CGWarpMouseCursorPosition(edgePoint)
                if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left) {
                    // Mark as our synthetic event so our tap lets it through
                    moveEvent.setIntegerValueField(.eventSourceUserData, value: self.syntheticEventMarker)
                    moveEvent.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.025)
            }

            // Move mouse back to original position
            CGWarpMouseCursorPosition(originalPosition)

            // Clear relocating flag - resume normal event handling
            self.eventClassifier.setRelocating(false)

            // Clean up temporary event tap if we created one
            if temporaryTapCreated {
                self.removeTemporaryEventTap()
            }

            // Show cursor again
            DispatchQueue.main.sync {
                NSCursor.unhide()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.publishStatus("Dock relocated to \(anchorDisplay.name)")
                self.resetStatusMessage(after: 2.0)
            }
        }
    }

    /// Gets the display ID where the dock is currently located
    private func getCurrentDockDisplayID() -> CGDirectDisplayID? {
        // Find the Dock application and get its window position
        let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first

        guard dockApp != nil else { return nil }

        // Use accessibility API to find dock window position
        let dockElement = AXUIElementCreateApplication(dockApp!.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(dockElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        // Get the position of the first dock window
        var positionValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &positionValue)

        guard posResult == .success else { return nil }

        var position = CGPoint.zero
        if let positionValue = positionValue, AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) {
            // Find which display contains this position
            for display in availableDisplays {
                if display.frame.contains(position) {
                    return display.id
                }
            }
        }

        return nil
    }

    private func handleMouseEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let result = eventClassifier.classify(
            inputType: type == .mouseMoved ? .mouseMoved : .other,
            location: event.location,
            eventSourceUserData: event.getIntegerValueField(.eventSourceUserData)
        )

        switch result.decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppressPhysicalDuringRelocation:
            return nil
        case let .suppressBlockedMovement(zone):
            blockedEventFeedback.recordBlocked(
                displayID: zone.displayID,
                displayName: zone.displayName
            )
            return nil
        }
    }

    private static let identityRegistryDefaultsKey = "displayIdentityRegistryV2"

    private static func getDisplayUUIDAlias(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private static func getCurrentDisplayReference(for displayID: CGDirectDisplayID) -> String {
        getDisplayUUIDAlias(for: displayID) ?? "DisplayID-\(displayID)"
    }

    private static func loadIdentityRegistry() -> DisplayIdentityRegistry {
        guard let data = UserDefaults.standard.data(forKey: identityRegistryDefaultsKey),
              let registry = try? JSONDecoder().decode(DisplayIdentityRegistry.self, from: data) else {
            return DisplayIdentityRegistry()
        }
        return registry
    }

    private func saveIdentityRegistry() {
        guard let data = try? JSONEncoder().encode(identityRegistry) else { return }
        UserDefaults.standard.set(data, forKey: Self.identityRegistryDefaultsKey)
    }

    private func fallbackDisplayName(
        frame: CGRect,
        mainFrame: CGRect,
        isPrimary: Bool,
        isBuiltIn: Bool
    ) -> String {
        if isBuiltIn { return "Built-in Display" }
        if isPrimary { return "Primary Display" }
        if frame.minX >= mainFrame.maxX { return "Right Display" }
        if frame.maxX <= mainFrame.minX { return "Left Display" }
        if frame.minY >= mainFrame.maxY { return "Bottom Display" }
        if frame.maxY <= mainFrame.minY { return "Top Display" }
        return "Secondary Display"
    }

    func refreshDisplays() {
        requestInventoryInvalidation(
            scope: .full,
            reasons: .explicitRefresh
        )
    }

    private func setupDisplayConfigurationMonitoring() {
        let context = DisplayConfigurationCallbackContext(monitor: self)
        displayConfigurationCallbackContext = context
        CGDisplayRegisterReconfigurationCallback(
            dockAnchorDisplayReconfigurationCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
    }

    fileprivate func handleDisplayConfigurationChange(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        guard let request = DisplayReconfigurationRefreshMapper.request(
            for: flags
        ) else { return }
        inventoryRefreshCoordinator.request(request)
    }

    private func resetStatusMessage(after delay: TimeInterval) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resetStatusMessage(after: delay)
            }
            return
        }

        let expectedRevision = statusMessages.currentRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            _ = self.statusMessages.publish(
                self.defaultStatusMessage,
                ifCurrent: expectedRevision
            )
        }
    }

    deinit {
        // Provider cancellation is observed by the profiler runner, and every
        // queued commit is generation-checked before touching this monitor.
        inventoryRefreshCoordinator?.cancel()

        // Ensure we're on the main thread for cleanup
        if Thread.isMainThread {
            stopMonitoring()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopMonitoring()
            }
        }

        // Make an in-flight callback retain no monitor before unregistering
        // the exact callback/context pair.
        if let context = displayConfigurationCallbackContext {
            context.invalidate()
            CGDisplayRemoveReconfigurationCallback(
                dockAnchorDisplayReconfigurationCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
            displayConfigurationCallbackContext = nil
        }

        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
}
