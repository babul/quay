import ComposableArchitecture
import Foundation

/// Thin TCA boundary for the terminal subsystem.
///
/// Commands mutate `TerminalTabManager.shared`; events flow out via
/// `AsyncStream` for cross-feature consumers (future: badges, notifications).
/// Tab opening is handled directly in ContentView (needs `modelContext`), so
/// `Command` only covers session-management operations.
struct TerminalClient: Sendable {
    var send: @MainActor (Command) -> Void
    var events: @Sendable () -> AsyncStream<Event>

    enum Command: Sendable {
        case closeTab(UUID)
        case selectTab(UUID)
        case disconnect(UUID)
        case reconnect(UUID)
    }

    enum Event: Sendable {
        case tabClosed(UUID)
        case childExited(UUID)
    }
}

// MARK: - DependencyKey

extension TerminalClient: DependencyKey {
    static var liveValue: TerminalClient {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        return TerminalClient(
            send: { @MainActor command in
                let mgr = TerminalTabManager.shared
                switch command {
                case .closeTab(let id):
                    mgr.closeTab(id: id)
                    continuation.yield(.tabClosed(id))
                case .selectTab(let id):
                    guard let tab = mgr.tabs.first(where: { $0.id == id }) else { return }
                    mgr.select(tab)
                case .disconnect(let id):
                    mgr.disconnectTab(id: id)
                case .reconnect(let id):
                    mgr.reconnectTab(id: id)
                }
            },
            events: { stream }
        )
    }

    static var testValue: TerminalClient {
        TerminalClient(
            send: { _ in },
            events: { AsyncStream { $0.finish() } }
        )
    }
}

extension DependencyValues {
    var terminalClient: TerminalClient {
        get { self[TerminalClient.self] }
        set { self[TerminalClient.self] = newValue }
    }
}
