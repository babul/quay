import Foundation
import Testing
@testable import Quay

@Suite("Sidebar collapse state", .serialized)
struct SidebarCollapseStateTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "QuayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("missing collapse state loads empty")
    func missingCollapseStateLoadsEmpty() throws {
        let defaults = try makeDefaults()
        #expect(SidebarCollapseState.load(from: defaults).isEmpty)
    }

    @Test("toggle collapsed folder persists UUID")
    func toggleCollapsedFolderPersistsUUID() throws {
        let defaults = try makeDefaults()
        let id = UUID()
        var collapsed: Set<UUID> = []

        SidebarCollapseState.setFolder(id, expanded: false, in: &collapsed, defaults: defaults)
        #expect(SidebarCollapseState.load(from: defaults) == Set([id]))

        SidebarCollapseState.setFolder(id, expanded: true, in: &collapsed, defaults: defaults)
        #expect(SidebarCollapseState.load(from: defaults).isEmpty)
    }

    @Test("prune removes stale collapsed folders")
    func pruneRemovesStaleCollapsedFolders() throws {
        let defaults = try makeDefaults()
        let kept = UUID()
        let stale = UUID()
        var collapsed: Set<UUID> = [kept, stale]
        SidebarCollapseState.save(collapsed, to: defaults)

        SidebarCollapseState.prune(&collapsed, keeping: [kept], defaults: defaults)

        #expect(collapsed == Set([kept]))
        #expect(SidebarCollapseState.load(from: defaults) == Set([kept]))
    }
}
