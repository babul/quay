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
