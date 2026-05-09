import CoreGraphics
import Foundation

enum SidebarCollapseState {
    static let storageKey = "sidebar.collapsedFolderIDs"
    static let sshConfigExpandedKey = "sidebar.sshConfigExpanded"

    static func loadSSHConfigExpanded(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sshConfigExpandedKey) != nil else { return true }
        return defaults.bool(forKey: sshConfigExpandedKey)
    }

    static func saveSSHConfigExpanded(_ expanded: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(expanded, forKey: sshConfigExpandedKey)
    }

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

    static let searchQueryStorageKey = "sidebar.searchQuery"

    static func loadWidth(from defaults: UserDefaults = .standard) -> CGFloat {
        loadCGFloat(forKey: widthStorageKey, default: defaultWidth, range: minimumWidth...maximumWidth, from: defaults)
    }

    static func saveWidth(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        saveCGFloat(width, forKey: widthStorageKey, range: minimumWidth...maximumWidth, to: defaults)
    }

    static func loadSidebarVisible(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibilityStorageKey) != nil else { return true }
        return defaults.bool(forKey: visibilityStorageKey)
    }

    static func saveSidebarVisible(_ isVisible: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(isVisible, forKey: visibilityStorageKey)
    }

    // MARK: Right sidebar width

    static let rightWidthStorageKey = "sidebar.right.width"
    static let rightMinimumWidth: CGFloat = 240
    static let rightDefaultWidth: CGFloat = 300
    static let rightMaximumWidth: CGFloat = 480

    static func loadRightWidth(from defaults: UserDefaults = .standard) -> CGFloat {
        loadCGFloat(forKey: rightWidthStorageKey, default: rightDefaultWidth, range: rightMinimumWidth...rightMaximumWidth, from: defaults)
    }

    static func saveRightWidth(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        saveCGFloat(width, forKey: rightWidthStorageKey, range: rightMinimumWidth...rightMaximumWidth, to: defaults)
    }

    // MARK: Private helpers

    private static func loadCGFloat(forKey key: String, default def: CGFloat, range: ClosedRange<CGFloat>, from defaults: UserDefaults) -> CGFloat {
        guard let stored = defaults.object(forKey: key) as? Double else { return def }
        let w = CGFloat(stored)
        return w.isFinite && range ~= w ? w : def
    }

    private static func saveCGFloat(_ value: CGFloat, forKey key: String, range: ClosedRange<CGFloat>, to defaults: UserDefaults) {
        guard value.isFinite, range ~= value else { return }
        defaults.set(Double(value), forKey: key)
    }
}
