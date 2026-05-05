import AppKit
import Foundation
import Observation
import SwiftUI

/// A single SSH tab. Long-lived: the `GhosttySurfaceView` is created once and
/// re-used across reconnects. Only the inner `ghostty_surface_t` is freed and
/// recreated on reconnect, so SwiftUI never tears down the `NSView`.
///
/// - The `AskpassServer` lives for the duration of the tab (not just one surface
///   lifetime) so re-auth on reconnect still works.
/// - `phase` is the per-tab session lifecycle; the view observes it to decide
///   what to show.
@Observable
@MainActor
final class TerminalTabItem: Identifiable {
    let id: UUID
    let profile: ConnectionProfile

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The long-lived surface view — `nil` only before the first connect.
    private(set) var surfaceView: GhosttySurfaceView?

    /// `AskpassServer` owned for the tab's lifetime, stopped only on tab close.
    private var askpassServer: AskpassServer?
    private var epoch: Int = 0

    /// Called when the child process exits. Set by external observers (e.g.,
    /// `TerminalClient`) to receive cross-feature child-exit events.
    var onChildExited: (() -> Void)?

    init(profile: ConnectionProfile) {
        self.id = UUID()
        self.profile = profile
    }

    // MARK: Lifecycle

    func connect() {
        // Clean up a previous surface (reconnect) without stopping the askpass server.
        disconnectSurface()
        phase = .starting
        do {
            let (config, askpass) = try SessionBootstrap.start(for: profile)
            if askpassServer == nil {
                askpassServer = askpass
            } else if let askpass {
                // Reconnecting: old server is still live; replace with fresh one.
                askpassServer?.stop()
                askpassServer = askpass
            }
            epoch &+= 1
            let view = GhosttySurfaceView(runtime: .shared, config: config)
            view.onBridgeCreated = { [weak self] bridge in
                guard let self else { return }
                bridge.onCloseRequest = { [weak self] in
                    self?.phase = .failed("Session ended")
                }
                bridge.onChildExited = { [weak self] _ in
                    self?.phase = .failed("Session ended")
                    self?.onChildExited?()
                }
            }
            surfaceView = view
            phase = .running
        } catch {
            phase = .failed("\(error)")
        }
    }

    func reconnect() {
        connect()
    }

    /// Tear down the surface but keep the askpass server alive for the tab's duration.
    private func disconnectSurface() {
        surfaceView = nil
    }

    /// Called when the tab is permanently closed. Stops the askpass server.
    func close() {
        askpassServer?.stop()
        askpassServer = nil
        surfaceView = nil
        phase = .idle
    }

    // MARK: Display

    var displayTitle: String {
        if let bridge = surfaceView?.bridge, !bridge.state.title.isEmpty {
            return bridge.state.title
        }
        return profile.name
    }

    var displayHost: String {
        guard let target = profile.sshTarget else { return profile.hostname }
        switch target.auth {
        case .sshConfigAlias(let alias): return alias
        default: break
        }
        let user = target.username.map { "\($0)@" } ?? ""
        let port = target.port.map { ":\($0)" } ?? ""
        return "\(user)\(target.hostname)\(port)"
    }
}
