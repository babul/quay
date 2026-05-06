import Foundation
import Observation

/// Manages all live SSH tabs. Owned by the root SwiftUI scene.
///
/// SwiftUI views (TerminalTabBar, ContentView) read this directly — no reducer
/// round-trip needed for the high-frequency path. The TCA `TerminalClient`
/// facade provides a thin command/event interface for cross-feature concerns.
@Observable
@MainActor
final class TerminalTabManager {
    static let shared = TerminalTabManager()

    enum AppQuitConfirmation: Equatable {
        case none
        case single
        case multiple(Int)
    }

    private(set) var tabs: [TerminalTabItem] = []
    private(set) var selectedTabID: UUID?
    private let connectTab: @MainActor (TerminalTabItem) -> Void

    init(connectTab: @escaping @MainActor (TerminalTabItem) -> Void = { $0.connect() }) {
        self.connectTab = connectTab
    }

    var selectedTab: TerminalTabItem? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    static func shouldConfirmClose(
        phase: TerminalTabItem.Phase,
        confirmActiveSessions: Bool
    ) -> Bool {
        guard confirmActiveSessions else { return false }

        switch phase {
        case .starting, .running:
            return true
        case .idle, .disconnected, .failed:
            return false
        }
    }

    func tabsRequiringCloseConfirmation(confirmActiveSessions: Bool) -> [TerminalTabItem] {
        tabs.filter {
            Self.shouldConfirmClose(
                phase: $0.phase,
                confirmActiveSessions: confirmActiveSessions
            )
        }
    }

    static func appQuitConfirmation(activeTabCount: Int) -> AppQuitConfirmation {
        switch activeTabCount {
        case 0:
            return .none
        case 1:
            return .single
        default:
            return .multiple(activeTabCount)
        }
    }

    // MARK: Commands

    /// Select an existing tab for `profile`, or open/connect the first one.
    @discardableResult
    func openOrSelectTab(for profile: ConnectionProfile) -> TerminalTabItem {
        if let existing = tabs.first(where: { $0.profile.id == profile.id && $0.kind == .ssh }) {
            select(existing)
            return existing
        }

        return openNewTab(for: profile)
    }

    /// Open a new tab for `profile` and immediately connect.
    @discardableResult
    func openNewTab(
        for profile: ConnectionProfile,
        kind: TerminalSessionKind = .ssh,
        localDirectoryOverride: String? = nil
    ) -> TerminalTabItem {
        let item = TerminalTabItem(
            profile: profile,
            kind: kind,
            localDirectoryOverride: localDirectoryOverride
        )
        tabs.append(item)
        select(item)
        connectTab(item)
        return item
    }

    @discardableResult
    func openSFTPTab(for profile: ConnectionProfile, localDirectoryOverride: String? = nil) -> TerminalTabItem {
        openNewTab(
            for: profile,
            kind: .sftp,
            localDirectoryOverride: localDirectoryOverride
        )
    }

    func select(_ item: TerminalTabItem) {
        guard selectedTabID != item.id else { return }
        selectedTabID = item.id

        // makeFirstResponder is deferred to TerminalSurfaceHostsView.updateNSView
        // after the selected surface is ordered frontmost.
    }

    func select(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectNextTab() { cycleTab(offset: 1) }
    func selectPreviousTab() { cycleTab(offset: -1) }

    private func cycleTab(offset: Int) {
        guard tabs.count > 1,
              let current = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == current })
        else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    func moveTab(id: UUID, before destinationID: UUID?) {
        guard id != destinationID else { return }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let item = tabs.remove(at: sourceIndex)

        guard let destinationID,
              let destinationIndex = tabs.firstIndex(where: { $0.id == destinationID })
        else {
            tabs.append(item)
            return
        }

        tabs.insert(item, at: destinationIndex)
    }

    func closeTab(_ item: TerminalTabItem) {
        item.close()
        tabs.removeAll { $0.id == item.id }
        if selectedTabID == item.id {
            selectedTabID = tabs.last?.id
        }
    }

    func closeTab(id: UUID) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        closeTab(item)
    }

    func disconnectTab(_ item: TerminalTabItem) {
        item.disconnect()
    }

    func disconnectTab(id: UUID) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        disconnectTab(item)
    }

    func reconnectTab(_ item: TerminalTabItem) {
        item.reconnect()
    }

    func reconnectTab(id: UUID) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        reconnectTab(item)
    }
}
