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

class DockMonitor: NSObject, ObservableObject {
    static let shared = DockMonitor()

    @Published var isActive = false
    @Published var anchoredDisplay: String = "Primary"
    @Published var statusMessage = "Dock Anchor Ready"
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var needsPermissionReset = false
    @Published private(set) var anchorIdentityState: AnchorIdentityState = .unavailable

    private(set) var reconciliationSnapshot = DisplayReconciliationSnapshot.empty
    private var identityRegistry = DockMonitor.loadIdentityRegistry()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private var anchorDisplayUUID: String = ""  // Hardware UUID for stable anchor tracking
    private var dockPosition: DockPosition = .bottom
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?

    /// Gets the current anchor display ID (derived from UUID)
    private var anchorDisplayID: CGDirectDisplayID {
        return availableDisplays.first { $0.uuid == anchorDisplayUUID }?.id ?? CGMainDisplayID()
    }

    /// Flag to suppress user mouse input during dock relocation
    private var isRelocating = false

    /// Magic value to identify our synthetic events (so we don't block our own events)
    private let syntheticEventMarker: Int64 = 0xD0C4A5C4 // "DOCKASCR" in hex-ish
    
    enum AnchorIdentityState: String {
        case unique
        case unavailable
        case ambiguous
        case unresolved
    }

    enum DockPosition {
        case bottom, left, right
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

    override init() {
        super.init()
        setupInitialState()
        setupNotificationObservers()
    }
    
    private func setupInitialState() {
        // Initialize with a runtime observation; the first complete snapshot
        // immediately replaces this with a reconciled effective identity.
        anchorDisplayUUID = Self.getCurrentDisplayReference(for: CGMainDisplayID())
        updateAvailableDisplays()
        detectCurrentDockPosition()
        setupDisplayConfigurationMonitoring()
        _ = requestAccessibilityPermissions()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .anchorDisplayChanged)
            .compactMap { $0.object as? DisplayAnchorChangeRequest }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self = self else { return }
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
        availableDisplays.first { $0.id == CGMainDisplayID() }?.uuid
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
        return availableDisplays.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? availableDisplays.first?.id
    }

    /// Re-evaluates the effective fallback without modifying the preferred
    /// anchor persisted by the user or active profile.
    private func applyDefaultAnchorIfNeeded() {
        validateCurrentAnchorDisplay()
        updateAnchoredDisplayName()
    }

    func updateAvailableDisplays() {
        let newDisplays = getAllDisplays()
        availableDisplays = newDisplays

        detectCurrentDockPosition()
        validateCurrentAnchorDisplay()
        updateAnchoredDisplayName()

        DispatchQueue.main.async {
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .displaysDidChange, object: nil)
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
        announceChange: Bool
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
            useConfiguredFallback(state: identityState(for: decision.preferredResolution))
            return decision
        }

        anchorDisplayUUID = display.uuid
        updateAnchoredDisplayName()
        if decision.usesFallback {
            useConfiguredFallback(
                state: identityState(for: decision.preferredResolution),
                display: display
            )
        } else if decision.isTemporaryExplicitSelection {
            anchorIdentityState = .ambiguous
            if announceChange {
                statusMessage = "Anchor changed to \(anchoredDisplay) (physical identity ambiguous)"
            }
        } else {
            anchorIdentityState = .unique
            if announceChange {
                statusMessage = "Anchor changed to \(anchoredDisplay)"
            }
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
        display: DisplayInfo? = nil
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
            statusMessage = "Ambiguous display identity - temporarily using \(defaultName)"
        case .unavailable:
            statusMessage = "Anchor display unavailable - temporarily using \(defaultName)"
        case .unresolved:
            statusMessage = "Anchor display reference unresolved - temporarily using \(defaultName)"
        case .unique:
            break
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

    private func detectCurrentDockPosition() {
        // Dock position detection - kept for internal logic if needed
        // The app primarily handles bottom dock position as left/right have predictable behavior
        dockPosition = .bottom
    }
    
    func requestAccessibilityPermissions() -> Bool {
        // Check if already trusted (without prompting)
        let trusted = AXIsProcessTrusted()

        if !trusted {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Accessibility permissions required"
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

        // Check if accessibility permissions are still granted
        if !checkAccessibilityPermissions() {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Accessibility permissions revoked - stopping monitoring"
                self?.stopMonitoring()
            }
            return
        }

        // Check if the event tap is still valid
        if let tap = eventTap, !CFMachPortIsValid(tap) {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Event tap invalidated - stopping monitoring"
                self?.stopMonitoring()
            }
            return
        }
    }

    func startMonitoring() {
        guard requestAccessibilityPermissions() else {
            statusMessage = "Please grant accessibility permissions in System Preferences"
            return
        }
        
        guard !isMonitoring else { return }
        
        updateAvailableDisplays()
        
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
                            monitor.statusMessage = "Recovered event tap after system disable"
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
            statusMessage = "Permission needs reset - remove and re-add app in Accessibility settings"
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        startPermissionMonitoring()
        DispatchQueue.main.async { [weak self] in
            self?.isActive = true
            self?.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
        }
    }

    func stopMonitoring() {
        stopPermissionMonitoring()
        guard isMonitoring else { return }

        isMonitoring = false

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
            self?.statusMessage = "Dock Anchor Stopped"
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
            statusMessage = "Cannot relocate dock - display identity is ambiguous"
            return
        }
        guard let anchorDisplay = availableDisplays.first(where: { $0.id == anchorDisplayID }) else {
            statusMessage = "Cannot relocate dock - anchor display not found"
            return
        }

        // Only relocate if we have multiple displays
        guard availableDisplays.count > 1 else {
            return
        }

        // Check if dock is already on the anchored display
        if let currentDockDisplay = getCurrentDockDisplayID(), currentDockDisplay == anchorDisplayID {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Dock is already on \(anchorDisplay.name)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "Relocating dock to \(anchorDisplay.name)..."
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

            // Set relocating flag - this causes the event tap to discard all mouse events
            // This is the key to preventing user mouse movement from interfering
            self.isRelocating = true

            // Hide cursor during the operation for better UX
            DispatchQueue.main.sync {
                NSCursor.hide()
            }

            // Create an event source for our synthetic events
            let eventSource = CGEventSource(stateID: .hidSystemState)

            // Get points for the movement
            let approachPoint = self.getApproachPoint(for: anchorDisplay)
            let edgePoint = self.getDockTriggerPoint(for: anchorDisplay)

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
            self.isRelocating = false

            // Clean up temporary event tap if we created one
            if temporaryTapCreated {
                self.removeTemporaryEventTap()
            }

            // Show cursor again
            DispatchQueue.main.sync {
                NSCursor.unhide()
            }

            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Dock relocated to \(anchorDisplay.name)"

                // Reset status after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
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

    /// Gets the approach point (slightly before the edge) for dock trigger animation
    private func getApproachPoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame
        let offset: CGFloat = 50 // Start 50 pixels from the edge

        switch dockPosition {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY - offset)
        case .left:
            return CGPoint(x: frame.minX + offset, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX - offset, y: frame.midY)
        }
    }

    /// Gets a point past the edge to create "pressure" against the screen edge
    private func getPastEdgePoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame
        let overshoot: CGFloat = 20 // Try to move 20 pixels past the edge

        switch dockPosition {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY + overshoot)
        case .left:
            return CGPoint(x: frame.minX - overshoot, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX + overshoot, y: frame.midY)
        }
    }

    /// Gets the point in the dock trigger zone for a display
    private func getDockTriggerPoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame

        switch dockPosition {
        case .bottom:
            // Bottom center of the display, at the very edge
            return CGPoint(x: frame.midX, y: frame.maxY - 1)
        case .left:
            // Left center of the display, at the very edge
            return CGPoint(x: frame.minX + 1, y: frame.midY)
        case .right:
            // Right center of the display, at the very edge
            return CGPoint(x: frame.maxX - 1, y: frame.midY)
        }
    }
    
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }

        // During dock relocation, suppress mouse events from real hardware
        // But allow our own synthetic events to pass through
        if isRelocating {
            // Check if this is one of our synthetic events by looking for our marker
            let userData = event.getIntegerValueField(.eventSourceUserData)
            if userData == syntheticEventMarker {
                // This is our synthetic event - let it through
                return Unmanaged.passUnretained(event)
            }
            // This is a real hardware event - discard it
            return nil
        }

        let location = event.location

        // Check if mouse is approaching dock trigger zone on non-anchor displays
        if shouldBlockDockMovement(at: location) {
            // Block the event by not passing it through
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
    
    private func shouldBlockDockMovement(at location: CGPoint) -> Bool {
        // Check if mouse is in dock trigger zone of non-anchor displays
        for display in availableDisplays {
            if display.id == anchorDisplayID { continue }
            
            let triggerZone = getDockTriggerZone(for: display)
            if triggerZone.contains(location) {
                DispatchQueue.main.async { [weak self] in
                    self?.statusMessage = "Blocked dock movement attempt to \(display.name)"
                    
                    // Reset status message after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self else { return }
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    }
                }
                return true
            }
        }
        
        return false
    }
    
    private func getDockTriggerZone(for display: DisplayInfo) -> CGRect {
        switch dockPosition {
        case .bottom:
            return CGRect(
                x: display.frame.minX,
                y: display.frame.maxY - 10,
                width: display.frame.width,
                height: 10
            )
        case .left:
            return CGRect(
                x: display.frame.minX,
                y: display.frame.minY,
                width: 10,
                height: display.frame.height
            )
        case .right:
            return CGRect(
                x: display.frame.maxX - 10,
                y: display.frame.minY,
                width: 10,
                height: display.frame.height
            )
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

    /// Builds all source observations first, then reconciles them once. Every
    /// display consumer uses the resulting snapshot rather than repeating a
    /// local first-match lookup.
    private func getAllDisplays() -> [DisplayInfo] {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount) == .success else {
            return []
        }

        displayIDs = Array(displayIDs.prefix(Int(displayCount))).filter {
            let bounds = CGDisplayBounds($0)
            return bounds.width > 0 && bounds.height > 0
        }

        let runtimes = displayIDs.map { displayID in
            DisplayRuntimeObservation(
                runtimeID: UInt64(displayID),
                uuidAlias: Self.getDisplayUUIDAlias(for: displayID),
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID) == 0
                    ? nil
                    : CGDisplaySerialNumber(displayID),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
            )
        }
        let metadata = getIOKitDisplayMetadata() + getSystemProfilerDisplayMetadata()
        var snapshot = DisplayReconciler.reconcile(
            runtimes: runtimes,
            metadata: metadata,
            priorRegistry: identityRegistry
        )

        // Migrate every occurrence of a value together. Ambiguous/unavailable
        // values remain byte-for-byte unchanged.
        let migrations = AppSettings.shared.reconcileDisplayReferences(using: snapshot)
        identityRegistry = snapshot.registry.recordingLegacyReferences(migrations)
        snapshot = snapshot.withRegistry(identityRegistry)
        reconciliationSnapshot = snapshot
        saveIdentityRegistry()

        let rawAliases = Dictionary(grouping: runtimes.compactMap { $0.uuidAlias }, by: { $0 })
            .mapValues(\.count)
        let frames = Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, CGDisplayBounds($0)) })
        let mainDisplayID = CGMainDisplayID()

        var displays = snapshot.displays.map { reconciled -> DisplayInfo in
            let displayID = CGDirectDisplayID(reconciled.runtime.runtimeID)
            let frame = frames[displayID] ?? .zero
            let isPrimary = displayID == mainDisplayID
            let explicitReference: String
            if reconciled.resolution == .unique, let persistent = reconciled.persistentReference {
                explicitReference = persistent
            } else if let alias = reconciled.runtime.uuidAlias,
                      rawAliases[alias] == 1 {
                explicitReference = alias
            } else {
                explicitReference = "DisplayID-\(displayID)"
            }

            let baseName = reconciled.friendlyName
                ?? fallbackDisplayName(for: displayID, frame: frame, mainDisplayID: mainDisplayID)
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

        // This ordering is presentation only and never participates in identity
        // assignment.
        displays.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY < rhs.frame.minY
        }
        return displays
    }

    private func getIOKitDisplayMetadata() -> [DisplayMetadataObservation] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var observations: [DisplayMetadataObservation] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let info = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any] else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            let vendor = uint32Value(info[kDisplayVendorID]) ?? 0
            let product = uint32Value(info[kDisplayProductID]) ?? 0
            let serial = uint32Value(info[kDisplaySerialNumber]).flatMap { $0 == 0 ? nil : $0 }
            let uuidAlias = stringValue(
                info["DisplayUUID"] ?? info["IODisplayUUID"] ?? info["UUID"]
            )
            let name = localizedProductName(info[kDisplayProductName])

            observations.append(DisplayMetadataObservation(
                source: "iokit",
                sourceID: "iokit-\(registryID)",
                uuidAlias: uuidAlias,
                vendorID: vendor,
                productID: product,
                serialNumber: serial,
                name: name,
                presentationPriority: 50
            ))
        }
        return observations
    }

    private func getSystemProfilerDisplayMetadata() -> [DisplayMetadataObservation] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["-json", "SPDisplaysDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let adapters = root["SPDisplaysDataType"] as? [[String: Any]] else {
                return []
            }

            var rawRecords: [(baseID: String, observation: DisplayMetadataObservation)] = []
            for adapter in adapters {
                guard let displays = adapter["spdisplays_ndrvs"] as? [[String: Any]] else { continue }
                for display in displays {
                    let name = stringValue(display["_name"])
                    let vendor = profilerUInt32(
                        display["_spdisplays_display-vendor-id"] ?? display["spdisplays_vendor-id"],
                        hexadecimalByDefault: true
                    ) ?? 0
                    let product = profilerUInt32(
                        display["_spdisplays_display-product-id"] ?? display["spdisplays_product-id"],
                        hexadecimalByDefault: true
                    ) ?? 0
                    let serial = profilerUInt32(
                        display["_spdisplays_display-serial-number"]
                            ?? display["_spdisplays_display-serial-number2"]
                            ?? display["spdisplays_display-serial-number"],
                        hexadecimalByDefault: false
                    ).flatMap { $0 == 0 ? nil : $0 }
                    let uuidAlias = stringValue(
                        display["_spdisplays_display-uuid"] ?? display["spdisplays_display-uuid"]
                    )
                    let type = stringValue(display["spdisplays_display_type"])
                        ?? stringValue(display["_spdisplays_display-type"])
                    let isBuiltIn = type.map {
                        $0.localizedCaseInsensitiveContains("built-in") ||
                        $0.localizedCaseInsensitiveContains("internal")
                    }
                    let resolution = stringValue(display["_spdisplays_resolution"])
                        ?? stringValue(display["spdisplays_resolution"])
                    let baseID = [
                        uuidAlias ?? "", String(vendor), String(product), String(serial ?? 0),
                        name ?? "", type ?? "", resolution ?? ""
                    ].joined(separator: "|")
                    rawRecords.append((
                        baseID: baseID,
                        observation: DisplayMetadataObservation(
                            source: "system_profiler",
                            sourceID: baseID,
                            uuidAlias: uuidAlias,
                            vendorID: vendor,
                            productID: product,
                            serialNumber: serial,
                            name: name,
                            isBuiltIn: isBuiltIn,
                            presentationPriority: 100
                        )
                    ))
                }
            }

            // Stable occurrence suffixes avoid depending on profiler array order.
            var occurrences: [String: Int] = [:]
            return rawRecords.sorted { $0.baseID < $1.baseID }.map { item in
                let occurrence = occurrences[item.baseID, default: 0]
                occurrences[item.baseID] = occurrence + 1
                let record = item.observation
                return DisplayMetadataObservation(
                    source: record.source,
                    sourceID: "profiler-\(item.baseID)#\(occurrence)",
                    uuidAlias: record.uuidAlias,
                    vendorID: record.vendorID,
                    productID: record.productID,
                    serialNumber: record.serialNumber,
                    name: record.name,
                    isBuiltIn: record.isBuiltIn,
                    presentationPriority: record.presentationPriority
                )
            }
        } catch {
            return []
        }
    }

    private func fallbackDisplayName(
        for displayID: CGDirectDisplayID,
        frame: CGRect,
        mainDisplayID: CGDirectDisplayID
    ) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 { return "Built-in Display" }
        if displayID == mainDisplayID { return "Primary Display" }

        let mainFrame = CGDisplayBounds(mainDisplayID)
        if frame.minX >= mainFrame.maxX { return "Right Display" }
        if frame.maxX <= mainFrame.minX { return "Left Display" }
        if frame.minY >= mainFrame.maxY { return "Bottom Display" }
        if frame.maxY <= mainFrame.minY { return "Top Display" }
        return "Secondary Display"
    }

    private func localizedProductName(_ value: Any?) -> String? {
        if let names = value as? [String: String] {
            return names["en_US"]
                ?? names["en"]
                ?? names.keys.sorted().compactMap { names[$0] }.first
        }
        if let names = value as? [String: Any] {
            return names.keys.sorted().compactMap { stringValue(names[$0]) }.first
        }
        return stringValue(value)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSString, value.length > 0 { return value as String }
        return nil
    }

    private func uint32Value(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt64, value <= UInt64(UInt32.max) { return UInt32(value) }
        if let value = value as? Int, value >= 0, value <= Int(UInt32.max) { return UInt32(value) }
        if let value = value as? NSNumber { return value.uint32Value }
        if let value = stringValue(value) { return UInt32(value) }
        return nil
    }

    private func profilerUInt32(_ value: Any?, hexadecimalByDefault: Bool) -> UInt32? {
        if !(value is String) && !(value is NSString) { return uint32Value(value) }
        guard var text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        text = text.lowercased()
        if text.hasPrefix("0x") { return UInt32(text.dropFirst(2), radix: 16) }
        if text.allSatisfy({ $0.isNumber }) {
            return UInt32(text, radix: hexadecimalByDefault ? 16 : 10)
        }
        if text.allSatisfy({ $0.isHexDigit }) { return UInt32(text, radix: 16) }
        return nil
    }

    func refreshDisplays() {
        updateAvailableDisplays()
    }

    private func updateCurrentAnchorDisplay() {
        // Get the current dock position and determine which display it's on
        let dockPosition = getCurrentDockPosition()
        let currentDisplayID = getDisplayForDockPosition(dockPosition)
        
        // Find the display name for the current anchor
        if let display = availableDisplays.first(where: { $0.id == currentDisplayID }) {
            DispatchQueue.main.async {
                self.anchoredDisplay = display.name
            }
        }
    }
    
    private func getCurrentDockPosition() -> DockPosition {
        // Get the current dock position from system preferences
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.dock", "orientation"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let orientation = output.trimmingCharacters(in: .whitespacesAndNewlines)
            
            switch orientation {
            case "left":
                return .left
            case "right":
                return .right
            default:
                return .bottom
            }
        } catch {
            return .bottom
        }
    }
    
    private func getDisplayForDockPosition(_ position: DockPosition) -> CGDirectDisplayID {
        // For bottom dock, find which display the dock is currently on
        if position == .bottom {
            // Get the current mouse position to determine which display the dock is on
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { screen in
                let frame = screen.frame
                return mouseLocation.x >= frame.minX && mouseLocation.x <= frame.maxX &&
                       mouseLocation.y >= frame.minY && mouseLocation.y <= frame.maxY
            }
            
            if let screen = screen,
               let screenNumber = screen.deviceDescription[
                   NSDeviceDescriptionKey("NSScreenNumber")
               ] as? UInt32 {
                return CGDirectDisplayID(screenNumber)
            }
        }
        
        // Fallback to main display
        return CGMainDisplayID()
    }
    
    private func setupDisplayConfigurationMonitoring() {
        // Register for display configuration changes
        CGDisplayRegisterReconfigurationCallback({ (displayID, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handleDisplayConfigurationChange(displayID: displayID, flags: flags)
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    
    private func handleDisplayConfigurationChange(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if flags.contains(.addFlag) {
                self.statusMessage = "New display detected - reconciling display identities"
                self.updateAvailableDisplays()

                let connectedRuntimeID = UInt64(displayID)
                let settings = AppSettings.shared
                let hotPlugDecision = DisplayHotPlugResolver.displayAdded(
                    runtimeID: connectedRuntimeID,
                    preferredReference: settings.selectedDisplayUUID,
                    profileReferences: settings.profiles.map(\.anchorDisplayUUID),
                    profileAutoActivation: settings.profiles.map(\.autoActivate),
                    currentAnchorIsUnique: self.anchorIdentityState == .unique,
                    autoRelocate: settings.autoRelocateDock,
                    snapshot: self.reconciliationSnapshot,
                    excludingInferredReferences: settings.nonPersistentDisplayReferences
                )
                var profileActivated = false

                if let profileIndex = hotPlugDecision.autoActivateProfileIndex {
                    let profile = settings.profiles[profileIndex]
                    let currentAnchorMatchesProfile =
                        settings.selectedDisplayUUID == profile.anchorDisplayUUID
                    if settings.activeProfileID != profile.id || !currentAnchorMatchesProfile {
                        settings.switchToProfile(profile)
                        self.statusMessage = "Auto-activated profile: \(profile.name)"
                        profileActivated = true
                    }
                }

                if !profileActivated && hotPlugDecision.restoresPreferredAnchor {
                    self.statusMessage = "Preferred display reconnected - restoring anchor to \(self.anchoredDisplay)"
                } else if hotPlugDecision.isAmbiguous {
                    self.statusMessage = "Ambiguous display identity - preserving the preferred anchor"
                }

                // Identity-dependent side effects all use the same snapshot
                // decision. Ambiguous additions can neither activate a profile
                // nor cause relocation.
                if !profileActivated && hotPlugDecision.permitsAutomaticRelocation {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.relocateDockToAnchoredDisplay()
                    }
                }
                self.resetStatusMessage(after: 3.0)

            } else if flags.contains(.removeFlag) {
                self.statusMessage = "Display removed - reconciling display identities"
                self.updateAvailableDisplays()
                if self.anchorIdentityState == .ambiguous {
                    self.statusMessage = "Ambiguous display identity - preserving the preferred anchor"
                } else if self.anchorIdentityState != .unique {
                    let defaultName = AppSettings.shared.defaultAnchorDisplay == .builtIn
                        ? "Built-in" : "Primary"
                    self.statusMessage = "Anchor display disconnected - temporarily using \(defaultName)"
                }
                self.resetStatusMessage(after: 3.0)

            } else if flags.contains(.movedFlag) || flags.contains(.desktopShapeChangedFlag) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    self.updateAvailableDisplays()
                    self.statusMessage = "Display arrangement updated"
                    self.objectWillChange.send()
                    self.resetStatusMessage(after: 2.0)
                }

            } else if flags.contains(.setMainFlag) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    self.updateAvailableDisplays()
                    self.statusMessage = "Main display updated"
                    if self.anchorIdentityState != .ambiguous,
                       AppSettings.shared.autoRelocateDock {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            self?.relocateDockToAnchoredDisplay()
                        }
                    }
                    self.resetStatusMessage(after: 3.0)
                }

            } else if flags.contains(.enabledFlag) ||
                        flags.contains(.disabledFlag) ||
                        flags.contains(.setModeFlag) {
                self.updateAvailableDisplays()
            }
        }
    }

    private func resetStatusMessage(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.statusMessage = self.isActive
                ? "Dock Anchor Active - Monitoring mouse movement"
                : "Dock Anchor Ready"
        }
    }

    deinit {
        // Ensure we're on the main thread for cleanup
        if Thread.isMainThread {
            stopMonitoring()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopMonitoring()
            }
        }
        
        // Remove display configuration callback
        CGDisplayRemoveReconfigurationCallback({ (displayID, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handleDisplayConfigurationChange(displayID: displayID, flags: flags)
        }, Unmanaged.passUnretained(self).toOpaque())
        
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
} 