import CoreGraphics

/// Converts every flag in a callback (not just the first matching branch) into
/// one coalescible inventory request. Arrangement/main-only callbacks stay on
/// the inexpensive path; any topology or mode flag upgrades the merged request
/// to a full inventory.
enum DisplayReconfigurationRefreshMapper {
    static func request(
        for flags: CGDisplayChangeSummaryFlags
    ) -> DisplayInventoryRefreshRequest? {
        var reasons: DisplayInventoryRefreshReasons = []
        var requiresFullInventory = false

        if flags.contains(.addFlag) {
            reasons.insert(.displayAdded)
            requiresFullInventory = true
        }
        if flags.contains(.removeFlag) {
            reasons.insert(.displayRemoved)
            requiresFullInventory = true
        }
        if flags.contains(.movedFlag) ||
            flags.contains(.desktopShapeChangedFlag) {
            reasons.insert(.arrangementChanged)
        }
        if flags.contains(.setMainFlag) {
            reasons.insert(.mainDisplayChanged)
        }
        if flags.contains(.enabledFlag) ||
            flags.contains(.disabledFlag) ||
            flags.contains(.setModeFlag) {
            reasons.insert(.displayModeChanged)
            requiresFullInventory = true
        }

        guard !reasons.isEmpty else { return nil }
        return .invalidation(
            scope: requiresFullInventory ? .full : .arrangement,
            reasons: reasons
        )
    }
}
