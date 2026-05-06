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

    @Test("Move tab before another tab reorders live tabs")
    func moveTabBeforeAnotherTabReordersLiveTabs() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let first = manager.openNewTab(for: ConnectionProfile(name: "prod", hostname: "prod.example.com"))
        let second = manager.openNewTab(for: ConnectionProfile(name: "stage", hostname: "stage.example.com"))
        let third = manager.openNewTab(for: ConnectionProfile(name: "dev", hostname: "dev.example.com"))

        manager.moveTab(id: third.id, before: second.id)

        #expect(manager.tabs.map(\.id) == [first.id, third.id, second.id])
    }

    @Test("Move tab to end when destination is nil")
    func moveTabToEndWhenDestinationIsNil() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let first = manager.openNewTab(for: ConnectionProfile(name: "prod", hostname: "prod.example.com"))
        let second = manager.openNewTab(for: ConnectionProfile(name: "stage", hostname: "stage.example.com"))
        let third = manager.openNewTab(for: ConnectionProfile(name: "dev", hostname: "dev.example.com"))

        manager.moveTab(id: first.id, before: nil)

        #expect(manager.tabs.map(\.id) == [second.id, third.id, first.id])
    }

    @Test("Moving tab onto itself is a no-op")
    func movingTabOntoItselfIsNoOp() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let first = manager.openNewTab(for: ConnectionProfile(name: "prod", hostname: "prod.example.com"))
        let second = manager.openNewTab(for: ConnectionProfile(name: "stage", hostname: "stage.example.com"))
        let originalOrder = manager.tabs.map(\.id)

        manager.moveTab(id: second.id, before: second.id)

        #expect(manager.tabs.map(\.id) == originalOrder)
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
    }

    @Test("Selected tab remains selected after reorder")
    func selectedTabRemainsSelectedAfterReorder() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let first = manager.openNewTab(for: ConnectionProfile(name: "prod", hostname: "prod.example.com"))
        let second = manager.openNewTab(for: ConnectionProfile(name: "stage", hostname: "stage.example.com"))
        let third = manager.openNewTab(for: ConnectionProfile(name: "dev", hostname: "dev.example.com"))
        manager.select(second)

        manager.moveTab(id: second.id, before: first.id)

        #expect(manager.tabs.map(\.id) == [second.id, first.id, third.id])
        #expect(manager.selectedTabID == second.id)
    }

    @Test("Closing selected tab removes it and selects the last remaining tab")
    func closingSelectedTabSelectsLastRemainingTab() {
        let manager = TerminalTabManager(connectTab: { _ in })
        let first = manager.openNewTab(for: ConnectionProfile(name: "prod", hostname: "prod.example.com"))
        let second = manager.openNewTab(for: ConnectionProfile(name: "stage", hostname: "stage.example.com"))
        let third = manager.openNewTab(for: ConnectionProfile(name: "dev", hostname: "dev.example.com"))
        manager.select(second)

        manager.closeTab(second)

        #expect(manager.tabs.map(\.id) == [first.id, third.id])
        #expect(manager.selectedTabID == third.id)
    }

    @Test("Close confirmation is required only for active phases when enabled")
    func closeConfirmationRequiredOnlyForActivePhasesWhenEnabled() {
        #expect(TerminalTabManager.shouldConfirmClose(phase: .starting, confirmActiveSessions: true))
        #expect(TerminalTabManager.shouldConfirmClose(phase: .running, confirmActiveSessions: true))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .idle, confirmActiveSessions: true))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .disconnected, confirmActiveSessions: true))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .failed("Session ended"), confirmActiveSessions: true))
    }

    @Test("Close confirmation setting disabled bypasses all phases")
    func closeConfirmationDisabledBypassesAllPhases() {
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .starting, confirmActiveSessions: false))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .running, confirmActiveSessions: false))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .idle, confirmActiveSessions: false))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .disconnected, confirmActiveSessions: false))
        #expect(!TerminalTabManager.shouldConfirmClose(phase: .failed("Session ended"), confirmActiveSessions: false))
    }
}
