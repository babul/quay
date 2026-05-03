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

    @State private var bundle: SessionBundle?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let bundle {
                GhosttyTerminalView(config: bundle.surfaceConfig)
                    .id(profile.id)
                    .navigationTitle(profile.name)
                    .navigationSubtitle(displayHost)
            } else if let startupError {
                ContentUnavailableView {
                    Label("Can't open this connection", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(startupError)
                }
            } else {
                ProgressView("Starting…")
            }
        }
        .onAppear {
            do {
                bundle = try SessionBundle.start(for: profile)
            } catch {
                startupError = "\(error)"
            }
        }
        .onDisappear {
            bundle?.shutdown()
            bundle = nil
        }
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
        surfaceConfig.command = cmd.command
        surfaceConfig.environment = cmd.environment
        surfaceConfig.waitAfterCommand = true
        surfaceConfig.scaleFactor = NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
        return SessionBundle(surfaceConfig: surfaceConfig, askpass: askpass)
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
