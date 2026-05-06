import CoreGraphics
import Foundation

enum SidebarCollapseState {
    static let storageKey = "sidebar.collapsedFolderIDs"

    static func load(from defaults: UserDefaults = .standard) -> Set<UUID> {
        let values = defaults.stringArray(forKey: storageKey) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    static func save(_ ids: Set<UUID>, to defaults: UserDefaults = .standard) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: storageKey)
    }

    static func setFolder(
        _ id: UUID,
        expanded: Bool,
        in collapsedIDs: inout Set<UUID>,
        defaults: UserDefaults = .standard
    ) {
        if expanded {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
        save(collapsedIDs, to: defaults)
    }

    static func prune(
        _ collapsedIDs: inout Set<UUID>,
        keeping folderIDs: Set<UUID>,
        defaults: UserDefaults = .standard
    ) {
        let pruned = collapsedIDs.intersection(folderIDs)
        guard pruned != collapsedIDs else { return }
        collapsedIDs = pruned
        save(pruned, to: defaults)
    }
}

enum SidebarLayoutState {
    static let widthStorageKey = "sidebar.width"
    static let visibilityStorageKey = "sidebar.isVisible"

    static let minimumWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 280
    static let maximumWidth: CGFloat = 640

    static func loadWidth(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let stored = defaults.object(forKey: widthStorageKey) as? Double else {
            return defaultWidth
        }

        let width = CGFloat(stored)
        guard isValid(width) else { return defaultWidth }
        return width
    }

    static func saveWidth(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        guard isValid(width) else { return }
        defaults.set(Double(width), forKey: widthStorageKey)
    }

    static func loadSidebarVisible(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibilityStorageKey) != nil else { return true }
        return defaults.bool(forKey: visibilityStorageKey)
    }

    static func saveSidebarVisible(_ isVisible: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(isVisible, forKey: visibilityStorageKey)
    }

    private static func isValid(_ width: CGFloat) -> Bool {
        width.isFinite && width >= minimumWidth && width <= maximumWidth
    }
}
