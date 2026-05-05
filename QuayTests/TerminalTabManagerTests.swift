import Testing
@testable import Quay

@MainActor
@Suite("Terminal tab manager")
struct TerminalTabManagerTests {
    @Test("Selecting an already selected tab leaves selection unchanged")
    func selectingAlreadySelectedTabIsNoOp() {
        let manager = TerminalTabManager()
        let profile = ConnectionProfile(name: "prod", hostname: "prod.example.com")
        let tab = TerminalTabItem(profile: profile)

        manager.select(tab)
        let selectedID = manager.selectedTabID

        manager.select(tab)

        #expect(manager.selectedTabID == selectedID)
    }

    @Test("Selecting another tab updates selected ID")
    func selectingAnotherTabUpdatesSelectedID() {
        let manager = TerminalTabManager()
        let first = TerminalTabItem(
            profile: ConnectionProfile(name: "prod", hostname: "prod.example.com")
        )
        let second = TerminalTabItem(
            profile: ConnectionProfile(name: "stage", hostname: "stage.example.com")
        )

        manager.select(first)
        manager.select(second)

        #expect(manager.selectedTabID == second.id)
    }

    @Test("Open or select creates first tab for profile")
    func openOrSelectCreatesFirstTab() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let profile = ConnectionProfile(name: "prod", hostname: "prod.example.com")

        let tab = manager.openOrSelectTab(for: profile)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs.first?.id == tab.id)
        #expect(manager.selectedTabID == tab.id)
    }

    @Test("Open or select reuses existing profile tab")
    func openOrSelectReusesExistingTab() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let profile = ConnectionProfile(name: "prod", hostname: "prod.example.com")
        let first = manager.openOrSelectTab(for: profile)

        let second = manager.openOrSelectTab(for: profile)

        #expect(manager.tabs.count == 1)
        #expect(second.id == first.id)
        #expect(manager.selectedTabID == first.id)
    }

    @Test("Open new tab creates duplicate profile session intentionally")
    func openNewTabCreatesDuplicateProfileSession() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let profile = ConnectionProfile(name: "prod", hostname: "prod.example.com")
        let first = manager.openOrSelectTab(for: profile)

        let second = manager.openNewTab(for: profile)

        #expect(manager.tabs.count == 2)
        #expect(second.id != first.id)
        #expect(manager.selectedTabID == second.id)
    }
}
