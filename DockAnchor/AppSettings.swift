//
//  AppSettings.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Foundation
import SwiftUI
import ServiceManagement

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum DefaultAnchorDisplay: String, CaseIterable {
    case builtIn = "Built-in Display"
    case main = "Main Display"
}

// MARK: - Profile Model
struct DockProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var anchorDisplayUUID: String
    var createdAt: Date
    var autoActivate: Bool  // Auto-activate when anchor display connects

    init(id: UUID = UUID(), name: String, anchorDisplayUUID: String, createdAt: Date = Date(), autoActivate: Bool = false) {
        self.id = id
        self.name = name
        self.anchorDisplayUUID = anchorDisplayUUID
        self.createdAt = createdAt
        self.autoActivate = autoActivate
    }

    // Custom decoder to handle migration from profiles without autoActivate field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        anchorDisplayUUID = try container.decode(String.self, forKey: .anchorDisplayUUID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        autoActivate = try container.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let userDefaults: UserDefaults
    private let managesLoginItem: Bool

    @Published var startAtLogin: Bool {
        didSet {
            userDefaults.set(startAtLogin, forKey: "startAtLogin")
            updateLoginItem()
        }
    }
    
    @Published var runInBackground: Bool {
        didSet {
            userDefaults.set(runInBackground, forKey: "runInBackground")
        }
    }
    
    @Published var showStatusIcon: Bool {
        didSet {
            userDefaults.set(showStatusIcon, forKey: "showStatusIcon")
            NotificationCenter.default.post(name: .statusIconVisibilityChanged, object: showStatusIcon)
        }
    }
    
    @Published var hideFromDock: Bool {
        didSet {
            userDefaults.set(hideFromDock, forKey: "hideFromDock")
            if oldValue != hideFromDock {
                // Notify the app to update activation policy
                NotificationCenter.default.post(name: .dockVisibilityChanged, object: hideFromDock)
            }
        }
    }

    @Published var autoRelocateDock: Bool {
        didSet {
            userDefaults.set(autoRelocateDock, forKey: "autoRelocateDock")
        }
    }

    @Published var defaultAnchorDisplay: DefaultAnchorDisplay {
        didSet {
            userDefaults.set(defaultAnchorDisplay.rawValue, forKey: "defaultAnchorDisplay")
            NotificationCenter.default.post(name: .defaultAnchorDisplayChanged, object: defaultAnchorDisplay)
        }
    }

    @Published var appTheme: AppTheme {
        didSet {
            userDefaults.set(appTheme.rawValue, forKey: "appTheme")
        }
    }

    // MARK: - Profiles
    @Published var profiles: [DockProfile] = [] {
        didSet {
            saveProfiles()
        }
    }

    @Published var activeProfileID: UUID? {
        didSet {
            if let idString = activeProfileID?.uuidString {
                userDefaults.set(idString, forKey: "activeProfileID")
            } else {
                userDefaults.removeObject(forKey: "activeProfileID")
            }
        }
    }

    /// The currently active profile (if any)
    var activeProfile: DockProfile? {
        guard let activeID = activeProfileID else { return nil }
        return profiles.first { $0.id == activeID }
    }

    /// Hardware UUID of the selected anchor display (stable across reboots/cable swaps)
    @Published var selectedDisplayUUID: String {
        didSet {
            userDefaults.set(selectedDisplayUUID, forKey: "selectedDisplayUUID")
            NotificationCenter.default.post(name: .anchorDisplayChanged, object: selectedDisplayUUID)
        }
    }

    /// Display ID for runtime use - computed from UUID via DockMonitor
    var selectedDisplayID: CGDirectDisplayID {
        get {
            return DockMonitor.shared.getDisplayID(forUUID: selectedDisplayUUID) ?? CGMainDisplayID()
        }
        set {
            // When setting by ID, look up the UUID
            if let uuid = DockMonitor.shared.getDisplayUUID(forID: newValue) {
                selectedDisplayUUID = uuid
            }
        }
    }
    
    init(
        userDefaults: UserDefaults = .standard,
        manageLoginItem: Bool = true,
        mainDisplayReference: String? = nil
    ) {
        self.userDefaults = userDefaults
        self.managesLoginItem = manageLoginItem

        // Tests and migrations can use an isolated defaults suite without
        // registering a real login item. Production still reflects the actual
        // SMAppService state.
        let actualLoginStatus: Bool
        if manageLoginItem {
            actualLoginStatus = SMAppService.mainApp.status == .enabled
        } else {
            actualLoginStatus = Self.boolPreference(
                defaults: userDefaults,
                forKey: "startAtLogin",
                defaultValue: false
            )
        }
        self.startAtLogin = actualLoginStatus

        self.runInBackground = Self.boolPreference(
            defaults: userDefaults,
            forKey: "runInBackground",
            defaultValue: true
        )
        self.showStatusIcon = Self.boolPreference(
            defaults: userDefaults,
            forKey: "showStatusIcon",
            defaultValue: true
        )
        self.hideFromDock = Self.boolPreference(
            defaults: userDefaults,
            forKey: "hideFromDock",
            defaultValue: false
        )
        self.autoRelocateDock = Self.boolPreference(
            defaults: userDefaults,
            forKey: "autoRelocateDock",
            defaultValue: true
        )

        // Get saved default anchor display or default to main display
        let savedDefaultAnchor = userDefaults.string(forKey: "defaultAnchorDisplay") ?? "Main Display"
        self.defaultAnchorDisplay = DefaultAnchorDisplay(rawValue: savedDefaultAnchor) ?? .main

        // Get saved theme or default to system
        let savedTheme = userDefaults.string(forKey: "appTheme") ?? "System"
        self.appTheme = AppTheme(rawValue: savedTheme) ?? .system

        // Load saved profiles
        self.profiles = Self.loadProfiles(from: userDefaults)

        // Load active profile ID
        if let activeIDString = userDefaults.string(forKey: "activeProfileID"),
           let activeID = UUID(uuidString: activeIDString) {
            self.activeProfileID = activeID
        } else {
            self.activeProfileID = nil
        }

        // Get saved display UUID, with migration from old display ID storage
        if let savedUUID = userDefaults.string(forKey: "selectedDisplayUUID") {
            self.selectedDisplayUUID = savedUUID
        } else if let oldDisplayID = userDefaults.object(forKey: "selectedDisplayID") as? Int {
            // Migrate from old display ID to UUID
            let displayID = CGDirectDisplayID(oldDisplayID)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) {
                let uuidRef = uuid.takeRetainedValue()
                self.selectedDisplayUUID = CFUUIDCreateString(nil, uuidRef) as String
            } else {
                // Fallback to main display UUID
                self.selectedDisplayUUID = mainDisplayReference ?? Self.getMainDisplayUUID()
            }
        } else {
            // Default to main display UUID
            self.selectedDisplayUUID = mainDisplayReference ?? Self.getMainDisplayUUID()
        }
        
        // Sync UserDefaults with actual system state
        userDefaults.set(actualLoginStatus, forKey: "startAtLogin")
    }
    
    private static func boolPreference(
        defaults userDefaults: UserDefaults,
        forKey key: String,
        defaultValue: Bool
    ) -> Bool {
        guard let value = userDefaults.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }

    private func updateLoginItem() {
        guard managesLoginItem else { return }
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }

    /// Gets the hardware UUID for the main display
    private static func getMainDisplayUUID() -> String {
        let mainDisplayID = CGMainDisplayID()
        if let uuid = CGDisplayCreateUUIDFromDisplayID(mainDisplayID) {
            let uuidRef = uuid.takeRetainedValue()
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return "DisplayID-\(mainDisplayID)"
    }

    // MARK: - Profile Management

    /// Creates a new profile with the current anchor display
    func createProfile(name: String, autoActivate: Bool = false) -> DockProfile {
        let profile = DockProfile(name: name, anchorDisplayUUID: selectedDisplayUUID, autoActivate: autoActivate)
        profiles.append(profile)
        return profile
    }

    /// Updates an existing profile
    func updateProfile(_ profile: DockProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
    }

    /// Deletes a profile
    func deleteProfile(_ profile: DockProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = nil
        }
    }

    /// Switches to a profile, updating the anchor display
    func switchToProfile(_ profile: DockProfile) {
        activeProfileID = profile.id
        selectedDisplayUUID = profile.anchorDisplayUUID

        // Trigger dock relocation if enabled
        if autoRelocateDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                DockMonitor.shared.relocateDockToAnchoredDisplay()
            }
        }
    }

    /// Deactivates the current profile (keeps current display setting)
    func deactivateProfile() {
        activeProfileID = nil
    }

    /// Saves the current display setting to the active profile
    func saveCurrentToActiveProfile() {
        guard let activeID = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        profiles[index].anchorDisplayUUID = selectedDisplayUUID
    }

    /// Migrates every persisted occurrence of a legacy display reference in one
    /// transaction. Unavailable, ambiguous, and malformed values are left
    /// untouched, and profile metadata/selection is not changed.
    @discardableResult
    func reconcileDisplayReferences(
        using snapshot: DisplayReconciliationSnapshot
    ) -> [String: String] {
        let references = [selectedDisplayUUID] + profiles.map(\.anchorDisplayUUID)
        let result = DisplayReferenceMigrator.migrate(references: references, using: snapshot)

        let migratedSelected = result.references[0]
        let migratedProfileReferences = Array(result.references.dropFirst())
        if migratedProfileReferences != profiles.map(\.anchorDisplayUUID) {
            var updatedProfiles = profiles
            for index in updatedProfiles.indices {
                updatedProfiles[index].anchorDisplayUUID = migratedProfileReferences[index]
            }
            profiles = updatedProfiles
        }
        if migratedSelected != selectedDisplayUUID {
            selectedDisplayUUID = migratedSelected
        }
        return result.migrations
    }

    /// Profile ordering is not identity evidence. If zero or multiple enabled
    /// profiles resolve to the connected display, no profile is selected.
    func findAutoActivateProfile(
        forRuntimeDisplayID runtimeID: UInt64,
        snapshot: DisplayReconciliationSnapshot
    ) -> DockProfile? {
        guard let index = DisplayProfileMatcher.uniqueMatch(
            for: runtimeID,
            references: profiles.map(\.anchorDisplayUUID),
            enabled: profiles.map(\.autoActivate),
            snapshot: snapshot
        ) else { return nil }
        return profiles[index]
    }

    // MARK: - Profile Persistence

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            userDefaults.set(data, forKey: "dockProfiles")
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    private static func loadProfiles(from userDefaults: UserDefaults) -> [DockProfile] {
        guard let data = userDefaults.data(forKey: "dockProfiles") else {
            return []
        }
        do {
            return try JSONDecoder().decode([DockProfile].self, from: data)
        } catch {
            print("Failed to load profiles: \(error)")
            return []
        }
    }
}

extension Notification.Name {
    static let statusIconVisibilityChanged = Notification.Name("statusIconVisibilityChanged")
    static let anchorDisplayChanged = Notification.Name("anchorDisplayChanged")
    static let dockVisibilityChanged = Notification.Name("dockVisibilityChanged")
    static let showMainWindowRequested = Notification.Name("showMainWindowRequested")
    static let displaysDidChange = Notification.Name("displaysDidChange")
    static let defaultAnchorDisplayChanged = Notification.Name("defaultAnchorDisplayChanged")
} 