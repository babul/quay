import AppKit
import Foundation

/// Pure functions for turning a `ConnectionProfile` into what a tab runs: the
/// surface that hosts the tab's `quay-supervisor`, and one spawn request per
/// attempt.
enum SessionBootstrap {
    enum StartError: Error, CustomStringConvertible {
        case incompleteProfile
        case askpassFailed(Error)
        case helperMissing(String)

        var description: String {
            switch self {
            case .incompleteProfile:
                return "This connection's auth fields are incomplete. Edit it and try again."
            case .askpassFailed(let e):
                return "Failed to start the askpass server: \(e)"
            case .helperMissing(let name):
                return "Bundled \(name) helper not found inside the app."
            }
        }
    }

    /// One attempt's worth of session.
    struct Session {
        var askpass: AskpassServer?
        /// What the supervisor is asked to run. `announce` is left for the
        /// tab, which knows the attempt number.
        var spawn: SupervisorProtocol.Spawn
        /// Short human name for the session, e.g. `ssh babul@host`.
        var displayTarget: String
        /// Whether the client running is itself proof enough of a session.
        ///
        /// True only for a client that owns its transport and connects lazily
        /// (see `SFTPClient.outlivesTransport`): waiting for a socket would
        /// report "connecting" over a prompt the user is already typing into.
        /// ssh — and OpenSSH's `sftp`, which connects eagerly — show nothing
        /// until the connection is up, so their TCP state is the honest signal.
        var connectedWhenClientRuns: Bool
    }

    static let supervisorName = "quay-supervisor"
    static let askpassName = "quay-askpass"

    /// Build an optional `AskpassServer` and the spawn request for one attempt.
    ///
    /// The caller is responsible for calling `askpass.stop()` when the tab closes
    /// (NOT on reconnect — the server must outlive the surface for re-auth).
    static func start(
        for profile: ConnectionProfile,
        kind: TerminalSessionKind = .ssh,
        localDirectoryOverride: String? = nil
    ) throws -> Session {
        guard let target = profile.sshTarget else {
            throw StartError.incompleteProfile
        }

        var askpass: AskpassServer?
        var askpassEnv: SSHCommandBuilder.AskpassEnv?
        let sftpClient = SFTPClient.preferred

        if let secretURI = secretRef(for: target) {
            guard let helperPath = bundledExecutable(named: askpassName) else {
                throw StartError.helperMissing(askpassName)
            }
            let server = AskpassServer(secretURI: secretURI)
            do { try server.start() } catch { throw StartError.askpassFailed(error) }
            askpass = server
            askpassEnv = .init(helperPath: helperPath, socketPath: server.socketPath)
        }

        let cmd = switch kind {
        case .ssh:
            SSHCommandBuilder.build(target, askpass: askpassEnv)
        case .sftp:
            SSHCommandBuilder.buildSFTP(target, askpass: askpassEnv, client: sftpClient)
        }

        var spawn = SupervisorProtocol.Spawn(argv: cmd.argv, environment: cmd.environment)
        if kind == .sftp {
            spawn.workingDirectory = normalizedLocalDirectory(localDirectoryOverride)
                ?? normalizedLocalDirectory(target.localDirectory)
                ?? defaultLocalDirectory()
        }

        return Session(
            askpass: askpass,
            spawn: spawn,
            displayTarget: displayTarget(for: target, kind: kind),
            connectedWhenClientRuns: kind == .sftp && sftpClient.outlivesTransport
        )
    }

    /// The surface config for a tab: its pty runs `quay-supervisor` for the
    /// tab's whole life, and sessions are spawned through it — so a reconnect
    /// continues on the screen the last session left.
    ///
    /// The user's login shell restores the environment a launchd-started app
    /// lacks (`SSH_AUTH_SOCK`, `PATH`), then execs the helper, which every
    /// session inherits it from.
    static func supervisorConfig(socketPath: String) throws -> GhosttySurfaceConfig {
        guard let helper = bundledExecutable(named: supervisorName) else {
            throw StartError.helperMissing(supervisorName)
        }
        var cfg = GhosttySurfaceConfig()
        cfg.command = wrapInLoginShell(shellSingleQuote(helper), environment: [:])
        cfg.environment = [SupervisorProtocol.socketEnvironmentKey: socketPath]
        cfg.waitAfterCommand = true
        cfg.scaleFactor = NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
        return cfg
    }

    /// The marker line: when it happened, what is being run, and which attempt.
    ///
    /// A tab accumulates these across a reconnect, so the screen reads as a log
    /// of the session's history — the timestamp is what makes "when did it drop"
    /// answerable after the fact.
    static func sessionMarker(
        target: String,
        attempt: Int,
        backoff: TimeInterval = 0,
        at date: Date
    ) -> String {
        let stamp = markerTimestampFormatter.string(from: date)
        guard attempt > 0 else { return "→ \(stamp)  \(target)" }
        guard backoff > 0 else { return "→ \(stamp)  \(target)  (attempt \(attempt))" }
        // The backoff this attempt waited out, so a run of them shows the
        // cycle stretching rather than just counting up.
        let waited = Int(backoff.rounded())
        return "→ \(stamp)  \(target)  (attempt \(attempt) · waited \(waited)s)"
    }

    /// The marker as written to the terminal: dimmed, so it reads as Quay's
    /// note rather than the session's output.
    static func announcement(_ marker: String) -> String {
        "\u{1B}[2m\(marker)\u{1B}[0m"
    }

    /// Fixed format, not locale-dependent: this lands in terminal output that
    /// gets scrolled back through, copied into tickets, and grepped.
    private static let markerTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func displayTarget(for target: SSHTarget, kind: TerminalSessionKind) -> String {
        let verb = kind == .sftp ? "sftp" : "ssh"
        // An alias profile runs `ssh <alias>`; announcing user@hostname would
        // name something the command never mentions.
        if case .sshConfigAlias = target.auth {
            return "\(verb) \(target.hostname)"
        }
        guard let username = target.username, !username.isEmpty else {
            return "\(verb) \(target.hostname)"
        }
        return "\(verb) \(username)@\(target.hostname)"
    }

    /// Wrap `inner` so it runs as: `$SHELL -l -c '<environment> exec <inner>'`.
    ///
    /// macOS apps launched by launchd have a minimal env. The login-shell wrap
    /// sources the user's profile, restoring SSH_AUTH_SOCK, PATH, etc.
    static func wrapInLoginShell(_ inner: String, environment: [String: String]) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let envPrefix = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellSingleQuote($0.value))" }
            .joined(separator: " ")
        let wrapped = envPrefix.isEmpty ? "exec \(inner)" : "exec env \(envPrefix) \(inner)"
        return "\(shell) -l -c \(shellSingleQuote(wrapped))"
    }

    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func secretRef(for target: SSHTarget) -> String? {
        switch target.auth {
        case .password(let ref):                    return ref
        case .privateKeyWithPassphrase(_, let ref): return ref
        default:                                    return nil
        }
    }

    static func bundledExecutable(named name: String) -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static func normalizedLocalDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return trimmed
    }

    static func defaultLocalDirectory() -> String? {
        if let stored = UserDefaults.standard.string(forKey: AppDefaultsKeys.sftpDefaultLocalDirectory),
           let normalized = normalizedLocalDirectory(stored) {
            return normalized
        }
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path
        return normalizedLocalDirectory(downloads)
    }
}
