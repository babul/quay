import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
final class LoginScriptRunner {
    private let steps: [LoginScriptStep]
    private let readVisibleText: () -> String
    private let sendText: (String) -> Void
    private let pollInterval: TimeInterval
    private let stepTimeout: TimeInterval

    private var task: Task<Void, Never>?

    init(
        steps: [LoginScriptStep],
        pollInterval: TimeInterval = 0.25,
        stepTimeout: TimeInterval = 30,
        readVisibleText: @escaping () -> String,
        sendText: @escaping (String) -> Void
    ) {
        self.steps = steps.normalizedLoginScriptSteps
        self.pollInterval = pollInterval
        self.stepTimeout = stepTimeout
        self.readVisibleText = readVisibleText
        self.sendText = sendText
    }

    func start() {
        stop()
        guard !steps.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        for step in steps {
            let deadline = Date().addingTimeInterval(stepTimeout)
            while !Task.isCancelled {
                if readVisibleText().contains(step.match) {
                    sendText(Self.terminalText(for: step.send))
                    break
                }

                guard Date() < deadline else { return }
                let nanoseconds = UInt64(max(0.001, pollInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    static func terminalText(for text: String) -> String {
        if text.hasSuffix("\r") || text.hasSuffix("\n") {
            return String(text.dropLast())
        }
        return text
    }
}

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
        case disconnected
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var displayedTitle: String
    private(set) var displayedUsername: String?

    /// The long-lived surface view — `nil` only before the first connect.
    private(set) var surfaceView: GhosttySurfaceView?

    /// `AskpassServer` owned for the tab's lifetime, stopped only on tab close.
    private var askpassServer: AskpassServer?
    private var loginScriptRunner: LoginScriptRunner?
    private var epoch: Int = 0

    /// Called when the child process exits. Set by external observers (e.g.,
    /// `TerminalClient`) to receive cross-feature child-exit events.
    var onChildExited: (() -> Void)?

    init(profile: ConnectionProfile) {
        self.id = UUID()
        self.profile = profile
        self.displayedTitle = profile.name
        self.displayedUsername = profile.username
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
                    self?.markSessionEnded()
                }
                bridge.onTitleChange = { [weak self] title in
                    guard let self else { return }
                    self.updateDisplayedTitle(title)
                }
                bridge.onChildExited = { [weak self] _ in
                    self?.markSessionEnded()
                    self?.onChildExited?()
                }
                let runner = LoginScriptRunner(
                    steps: self.profile.loginScriptSteps,
                    readVisibleText: { [weak bridge] in bridge?.visibleText() ?? "" },
                    sendText: { [weak bridge] text in
                        bridge?.sendText(text)
                        bridge?.sendReturnKey()
                    }
                )
                self.loginScriptRunner = runner
                runner.start()
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

    func disconnect() {
        loginScriptRunner?.stop()
        loginScriptRunner = nil
        surfaceView?.disconnectProcess()
        phase = .disconnected
    }

    private func markSessionEnded() {
        loginScriptRunner?.stop()
        loginScriptRunner = nil
        if phase != .disconnected {
            phase = .failed("Session ended")
        }
    }

    /// Tear down the surface but keep the askpass server alive for the tab's duration.
    private func disconnectSurface() {
        loginScriptRunner?.stop()
        loginScriptRunner = nil
        surfaceView = nil
    }

    /// Called when the tab is permanently closed. Stops the askpass server.
    func close() {
        loginScriptRunner?.stop()
        loginScriptRunner = nil
        askpassServer?.stop()
        askpassServer = nil
        surfaceView = nil
        phase = .idle
    }

    // MARK: Display

    var displayTitle: String {
        displayedTitle
    }

    var displayHost: String {
        guard let target = profile.sshTarget else { return profile.hostname }
        switch target.auth {
        case .sshConfigAlias(let alias): return alias
        default: break
        }
        let user = displayedUsername.map { "\($0)@" } ?? ""
        let port = target.port.map { ":\($0)" } ?? ""
        return "\(user)\(target.hostname)\(port)"
    }

    private func updateDisplayedTitle(_ terminalTitle: String) {
        guard !terminalTitle.isEmpty else {
            displayedTitle = profile.name
            displayedUsername = profile.username
            return
        }

        let promptPrefix = terminalTitle.split(separator: ":", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let promptPrefix, !promptPrefix.isEmpty else {
            displayedTitle = terminalTitle
            return
        }

        if let atIndex = promptPrefix.firstIndex(of: "@") {
            let username = String(promptPrefix[..<atIndex])
            let host = String(promptPrefix[promptPrefix.index(after: atIndex)...])
            displayedUsername = username.isEmpty ? profile.username : username
            displayedTitle = host.isEmpty ? profile.name : host
        } else {
            displayedTitle = promptPrefix
        }
    }
}
