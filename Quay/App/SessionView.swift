import AppKit
import Foundation
import SwiftUI

/// Live SSH session for a `ConnectionProfile`.
///
/// Setup, in order:
///   1. Build the `SSHCommand` (`SSHCommandBuilder.build(profile.sshTarget)`).
///   2. If the auth method needs a secret, spin up an `AskpassServer` and
///      rebuild the command so its env carries `SSH_ASKPASS_*`.
///   3. Hand the command + env to `GhosttyTerminalView`. libghostty forks
///      `/usr/bin/ssh`, which on its first password prompt execs our
///      bundled helper, which reads from the AskpassServer socket.
///
/// The askpass server's lifetime is tied to this view — it shuts down when
/// the session is replaced or the window closes.
struct SessionView: View {
    let profile: ConnectionProfile

    @State private var phase: Phase = .idle
    @State private var bundle: SessionBundle?
    @State private var epoch: Int = 0

    enum Phase: Equatable {
        case idle              // never connected, or after manual disconnect
        case starting
        case running
        case failed(String)
    }

    var body: some View {
        contentBody
            .navigationTitle(profile.name)
            .navigationSubtitle(displayHost)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    sessionActionButton
                }
            }
            // SwiftUI's NavigationSplitView keeps the detail view alive as
            // selection changes — onChange(profile) makes sure switching
            // sidebar entries actually re-runs the connect flow.
            .onChange(of: profile.id, initial: true) { _, _ in
                connect()
            }
            .onDisappear {
                disconnect()
            }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch phase {
        case .idle:
            ContentUnavailableView {
                Label("Disconnected", systemImage: "powerplug.fill")
            } description: {
                Text("Hit Connect in the toolbar to start a session.")
            } actions: {
                Button("Connect") { connect() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        case .starting:
            ProgressView("Connecting…")
        case .running:
            if let bundle {
                GhosttyTerminalView(config: bundle.surfaceConfig)
                    // The id ties to (profile, epoch) so reconnect actually
                    // tears the NSView down and recreates the surface.
                    .id("\(profile.id)-\(epoch)")
            } else {
                ProgressView("Connecting…")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't open this connection", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { connect() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private var sessionActionButton: some View {
        switch phase {
        case .idle:
            Button {
                connect()
            } label: {
                Label("Connect", systemImage: "powerplug.fill")
            }
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .running:
            Menu {
                Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
                Button("Disconnect", systemImage: "powerplug", role: .destructive) {
                    disconnect()
                    phase = .idle
                }
            } label: {
                Label("Session", systemImage: "powerplug.fill")
            }
        case .failed:
            Button {
                connect()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
    }

    private func connect() {
        // Always start from a clean slate — even if a previous session is
        // still alive (e.g. the user hit "Reconnect" while running).
        disconnect()

        phase = .starting
        do {
            bundle = try SessionBundle.start(for: profile)
            epoch &+= 1
            phase = .running
        } catch {
            bundle = nil
            phase = .failed("\(error)")
        }
    }

    private func reconnect() {
        connect()
    }

    private func disconnect() {
        bundle?.shutdown()
        bundle = nil
    }

    private var displayHost: String {
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

/// Holds the ephemeral resources a single session owns.
private final class SessionBundle: @unchecked Sendable {
    let surfaceConfig: GhosttySurfaceConfig
    private let askpass: AskpassServer?

    private init(surfaceConfig: GhosttySurfaceConfig, askpass: AskpassServer?) {
        self.surfaceConfig = surfaceConfig
        self.askpass = askpass
    }

    func shutdown() {
        askpass?.stop()
    }

    enum StartError: Error, CustomStringConvertible {
        case incompleteProfile
        case askpassFailed(Error)
        case helperMissing

        var description: String {
            switch self {
            case .incompleteProfile:
                return "This connection's auth fields are incomplete. Edit it and try again."
            case .askpassFailed(let e):
                return "Failed to start the askpass server: \(e)"
            case .helperMissing:
                return "Bundled quay-askpass helper not found inside the app."
            }
        }
    }

    static func start(for profile: ConnectionProfile) throws -> SessionBundle {
        guard let target = profile.sshTarget else {
            throw StartError.incompleteProfile
        }

        // TEMPORARY DEBUG: log the env Quay (and therefore the spawned ssh)
        // see at session start. Remove with the matching -v flag in the
        // SSH builder once known_hosts behaviour is sorted out.
        let env = ProcessInfo.processInfo.environment
        let keys = ["HOME", "USER", "SHELL", "PATH", "SSH_AUTH_SOCK", "TMPDIR"]
        let summary = keys.map { "\($0)=\(env[$0] ?? "(unset)")" }.joined(separator: " | ")
        NSLog("Quay session env: %@", summary)

        // Set up askpass plumbing only when the auth method needs it.
        var askpass: AskpassServer?
        var askpassEnv: SSHCommandBuilder.AskpassEnv?

        if let secretURI = secretRef(for: profile, target: target) {
            guard let helperPath = bundledHelperPath() else {
                throw StartError.helperMissing
            }
            let server = AskpassServer(secretURI: secretURI)
            do {
                try server.start()
            } catch {
                throw StartError.askpassFailed(error)
            }
            askpass = server
            askpassEnv = .init(helperPath: helperPath, socketPath: server.socketPath)
        }

        let cmd = SSHCommandBuilder.build(target, askpass: askpassEnv)
        var surfaceConfig = GhosttySurfaceConfig()
        // Run ssh through the user's login shell so it sees the same
        // environment as their terminal: $HOME, $SSH_AUTH_SOCK, $PATH from
        // .zprofile/.zshenv, etc. Quay.app inherits launchd's minimal env
        // and that's what trips up known_hosts lookups + ssh-agent auth.
        surfaceConfig.command = wrapInLoginShell(cmd.command, askpassEnv: cmd.environment)
        // Askpass env is now embedded inside the wrap script's `env` prefix;
        // leave libghostty's env_vars empty so the user's profile can't
        // unset SSH_ASKPASS_* before exec.
        surfaceConfig.environment = [:]
        surfaceConfig.waitAfterCommand = true
        surfaceConfig.scaleFactor = NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
        return SessionBundle(surfaceConfig: surfaceConfig, askpass: askpass)
    }

    /// Wrap `inner` so it runs as: `$SHELL -l -c '<askpass env> exec <inner>'`.
    ///
    /// Why login shell: macOS apps spawned by launchd have a minimal env.
    /// Wrapping in `-l` sources the user's profile (`.zprofile`, `.zshenv`,
    /// etc.), restoring `HOME` invariants, `SSH_AUTH_SOCK`, custom `PATH`,
    /// and any other env the user's terminal sees. This is the same trick
    /// Tabby uses to make ssh feel native.
    ///
    /// Askpass env vars are placed AFTER profile sourcing (via inline `env`)
    /// so the user's profile can't accidentally unset `DISPLAY` or
    /// `SSH_ASKPASS` before ssh runs.
    private static func wrapInLoginShell(_ inner: String, askpassEnv: [String: String]) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let envPrefix = askpassEnv
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(shellSingleQuote($0.value))" }
            .joined(separator: " ")
        let inner = envPrefix.isEmpty ? "exec \(inner)" : "exec env \(envPrefix) \(inner)"
        return "\(shell) -l -c \(shellSingleQuote(inner))"
    }

    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Returns the secret reference URI tied to the chosen auth method,
    /// or `nil` if no secret is involved.
    private static func secretRef(
        for profile: ConnectionProfile,
        target: SSHTarget
    ) -> String? {
        switch target.auth {
        case .password(let ref): return ref
        case .privateKeyWithPassphrase(_, let ref): return ref
        default: return nil
        }
    }

    private static func bundledHelperPath() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/quay-askpass")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }
}
