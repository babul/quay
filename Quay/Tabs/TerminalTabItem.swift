import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
final class LoginScriptRunner {
    private let steps: [LoginScriptStep]
    private let resolver: ReferenceResolver
    private let readVisibleText: () -> String
    private let sendText: (String) -> Void
    private let pollInterval: TimeInterval
    private let stepTimeout: TimeInterval

    private var task: Task<Void, Never>?

    init(
        steps: [LoginScriptStep],
        resolver: ReferenceResolver = ReferenceResolver(),
        pollInterval: TimeInterval = 0.25,
        stepTimeout: TimeInterval = 30,
        readVisibleText: @escaping () -> String,
        sendText: @escaping (String) -> Void
    ) {
        self.steps = steps.normalizedLoginScriptSteps
        self.resolver = resolver
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
        // Resolve any Keychain-backed steps before entering the match loop so
        // Touch ID (if required) appears as a single burst at connect time.
        var resolvedSends: [UUID: String] = [:]
        for step in steps where step.sendRef != nil {
            guard let uri = step.sendRef else { continue }
            do {
                let bytes = try await resolver.resolve(uri)
                resolvedSends[step.id] = bytes.unsafeUTF8String() ?? ""
            } catch {
                return  // Touch ID cancelled or item missing — abort the script
            }
        }

        for step in steps {
            let send = resolvedSends[step.id] ?? step.send
            let deadline = Date().addingTimeInterval(stepTimeout)
            while !Task.isCancelled {
                if readVisibleText().contains(step.match) {
                    sendText(Self.terminalText(for: send))
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
    let kind: TerminalSessionKind
    let localDirectoryOverride: String?

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
    private var didReportConnect = false

    /// The long-lived surface view — `nil` only before the first connect.
    private(set) var surfaceView: GhosttySurfaceView?

    /// `AskpassServer` owned for the tab's lifetime, stopped only on tab close.
    private var askpassServer: AskpassServer?
    private var loginScriptRunner: LoginScriptRunner?
    /// Called when the child process exits. Set by external observers (e.g.,
    /// `TerminalClient`) to receive cross-feature child-exit events.
    var onChildExited: (() -> Void)?

    init(
        profile: ConnectionProfile,
        kind: TerminalSessionKind = .ssh,
        localDirectoryOverride: String? = nil
    ) {
        self.id = UUID()
        self.profile = profile
        self.kind = kind
        self.localDirectoryOverride = localDirectoryOverride
        self.displayedTitle = kind == .sftp ? "\(profile.name) SFTP" : profile.name
        self.displayedUsername = profile.username
    }

    // MARK: Lifecycle

    func connect() {
        // Clean up a previous surface (reconnect) without stopping the askpass server.
        disconnectSurface()
        didReportConnect = false
        phase = .starting
        do {
            let (config, askpass) = try SessionBootstrap.start(
                for: profile,
                kind: kind,
                localDirectoryOverride: localDirectoryOverride
            )
            if askpassServer == nil {
                askpassServer = askpass
            } else if let askpass {
                // Reconnecting: old server is still live; replace with fresh one.
                askpassServer?.stop()
                askpassServer = askpass
            }
            let view = GhosttySurfaceView(runtime: .shared, config: config)
            view.onBridgeCreated = { [weak self] bridge in
                guard let self else { return }
                bridge.onCloseRequest = { [weak self] in
                    self?.markSessionEnded()
                }
                bridge.onTitleChange = { [weak self] title in
                    guard let self else { return }
                    self.updateFromTerminalTitle(title)
                    if !self.didReportConnect, !title.isEmpty {
                        self.didReportConnect = true
                        NotificationCenter.default.post(name: .connectionConnected, object: self.id)
                    }
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

    func markSessionEnded() {
        loginScriptRunner?.stop()
        loginScriptRunner = nil
        if phase != .disconnected {
            phase = .disconnected
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
        kind == .sftp ? "\(profile.name) SFTP" : profile.name
    }

    var terminalBackgroundColor: NSColor {
        surfaceView?.bridge?.state.backgroundColor
            ?? GhosttyResolvedAppearance.backgroundColor(from: GhosttyRuntime.shared.config)
    }

    var terminalBackgroundOpacity: Double {
        surfaceView?.bridge?.state.backgroundOpacity
            ?? GhosttyResolvedAppearance.backgroundOpacity(from: GhosttyRuntime.shared.config)
    }

    var currentWorkingDirectory: String? {
        surfaceView?.bridge?.state.pwd?.path
    }

    func updateFromTerminalTitle(_ terminalTitle: String) {
        guard !terminalTitle.isEmpty else {
            displayedUsername = profile.username
            return
        }

        let promptPrefix = terminalTitle.split(separator: ":", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let promptPrefix, !promptPrefix.isEmpty else { return }

        if let atIndex = promptPrefix.firstIndex(of: "@") {
            let username = String(promptPrefix[..<atIndex])
            displayedUsername = username.isEmpty ? profile.username : username
        }
    }
}
