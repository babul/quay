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
}
