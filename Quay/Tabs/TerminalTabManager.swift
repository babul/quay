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

    private(set) var tabs: [TerminalTabItem] = []
    private(set) var selectedTabID: UUID?

    var selectedTab: TerminalTabItem? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: Commands

    /// Open a new tab for `profile` and immediately connect.
    @discardableResult
    func openTab(for profile: ConnectionProfile) -> TerminalTabItem {
        // Reuse an existing idle tab for the same profile if one exists,
        // so rapidly re-clicking the sidebar doesn't pile up duplicate tabs.
        if let existing = tabs.first(where: { $0.profile.id == profile.id && $0.canReconnectInPlace }) {
            select(existing)
            existing.connect()
            return existing
        }
        let item = TerminalTabItem(profile: profile)
        tabs.append(item)
        select(item)
        item.connect()
        return item
    }

    func select(_ item: TerminalTabItem) {
        guard selectedTabID != item.id else { return }
        selectedTabID = item.id

        // makeFirstResponder is deferred to TerminalSurfaceHostsView.updateNSView
        // after the selected surface is ordered frontmost.
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

private extension TerminalTabItem {
    var canReconnectInPlace: Bool {
        switch phase {
        case .idle, .disconnected, .failed:
            return true
        case .starting, .running:
            return false
        }
    }
}
