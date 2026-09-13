import AppKit
import Foundation

/// Pure functions for building an SSH surface config from a `ConnectionProfile`.
///
/// Previously embedded in `SessionView.SessionBundle`. Extracted so both the
/// old single-surface path and the new `TerminalTabItem` can share them.
enum SessionBootstrap {
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

    /// One attempt's worth of session: the surface to host it (only needed for
    /// the first attempt in a tab) and the command line that starts it.
    struct Session {
        /// Config for the tab's host shell. Used once per tab; later attempts
        /// are typed into the shell that is already running.
        var config: GhosttySurfaceConfig
        var askpass: AskpassServer?
        /// What to type into the host shell to start the session.
        var commandLine: String
        /// Executable names that count as this session's client, for spotting
        /// it in the pty's foreground process group.
        var clientNames: Set<String>
        /// Short human name for the session, e.g. `ssh babul@host`.
        var displayTarget: String
    }

    /// Build the host-shell config, an optional `AskpassServer`, and the command
    /// line for one attempt.
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
            guard let helperPath = bundledHelperPath() else {
                throw StartError.helperMissing
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
            SSHCommandBuilder.buildSFTP(
                target,
                askpass: askpassEnv,
                client: sftpClient
            )
        }
        var cfg = GhosttySurfaceConfig()
        cfg.command = hostShellCommand()
        if kind == .sftp {
            cfg.workingDirectory = normalizedLocalDirectory(localDirectoryOverride)
                ?? normalizedLocalDirectory(target.localDirectory)
                ?? defaultLocalDirectory()
        }
        // Stable for the tab, so it doesn't have to be retyped per attempt —
        // which also means editing a profile's terminal type only takes effect
        // in a new tab. `sessionCommandLine` filters "TERM" back out to match.
        cfg.environment = ["TERM": target.remoteTerminalType.rawValue]
        cfg.waitAfterCommand = true
        cfg.scaleFactor = NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0

        return Session(
            config: cfg,
            askpass: askpass,
            commandLine: sessionCommandLine(cmd),
            clientNames: clientNames(for: kind, sftpClient: sftpClient),
            displayTarget: displayTarget(for: target, kind: kind)
        )
    }

    /// The tab's pty runs this for the tab's whole life; sessions are typed into
    /// it, so a reconnect continues on the screen it already has.
    ///
    /// The user's login shell restores the environment a launchd-started app
    /// lacks (`SSH_AUTH_SOCK`, `PATH`), then hands the pty to a bare `sh` with
    /// no prompt and no startup file of its own, so the only thing on screen is
    /// the session.
    static func hostShellCommand() -> String {
        // `stty -echo` runs as an argument, before the interactive shell reads
        // anything, so it is never echoed itself; `+o emacs` turns off the line
        // editor, which does its own echoing regardless of tty settings.
        // Together they keep Quay's typed command off the screen — the session
        // announces itself instead (see `announced`).
        //
        // PS1 is re-applied on the inner exec: a shell imports it as a plain
        // variable, not an exported one, so it would be lost across the exec.
        let interactive = "exec env PS1=\(shellSingleQuote(hostShellPrompt)) ENV= /bin/sh -i +o emacs"
        return wrapInLoginShell(
            "env ENV= /bin/sh -c \(shellSingleQuote("stty -echo; " + interactive))",
            askpassEnv: [:]
        )
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

    /// Fixed format, not locale-dependent: this lands in terminal output that
    /// gets scrolled back through, copied into tickets, and grepped.
    private static let markerTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Prefix a command with a dim one-liner naming the session.
    ///
    /// The host shell's echo is off, so without this the screen would give no
    /// sign that a session started — which matters most on a retry, where the
    /// only other clue is the status pill.
    ///
    /// `printf '%s'` rather than interpolating: a target containing `%` would
    /// otherwise be read as a format specifier.
    static func announced(_ commandLine: String, marker: String) -> String {
        "printf '\\033[2m%s\\033[0m\\n' \(shellSingleQuote(marker)); \(commandLine)"
    }

    /// The host shell's prompt: invisible, and it puts the terminal back to a
    /// sane state.
    ///
    /// A prompt is printed right after each session exits, which is exactly
    /// when the remote's leftover modes need clearing. Without this, a remote
    /// shell that enabled bracketed paste (mode 2004) and died without
    /// disabling it leaves the emulator wrapping the next command Quay types in
    /// `ESC[200~ … ESC[201~`, and the host shell tries to run `00~/usr/bin/ssh`.
    /// The same goes for an editor killed mid-session leaving mouse reporting
    /// on.
    ///
    /// Deliberately absent: leaving the alternate screen (`ESC[?1049l`).
    /// It *restores a saved cursor*, so on a terminal that was never in the alt
    /// screen it sends the cursor home and the next session overwrites the
    /// scrollback from the top. Only modes with no cursor or screen side
    /// effects belong here.
    ///
    /// Mouse input is reset here for a second reason: wheel and motion events
    /// are forwarded to the pty without the input gate, so a session that died
    /// with reporting on would write `ESC[M…` into the host shell's stdin — and
    /// one that died inside a full-screen program would turn every scroll into
    /// arrow keys (mode 1007) and corrupt the next typed command.
    ///
    /// Wrapped in `\[ \]` so the shell's line editor doesn't count these
    /// zero-width bytes when it places the cursor.
    static let hostShellPrompt =
        "\\["
        + "\u{1B}[?2004l"   // bracketed paste off
        + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l"  // mouse reporting off
        + "\u{1B}[?1007l"  // wheel scrolls, rather than sending arrow keys
        + "\u{1B}[?1l"     // normal cursor keys
        + "\u{1B}[?25h"    // cursor visible
        + "\u{1B}[0m"      // no leftover colours
        + "\\]"


    /// The command line typed into the host shell. Per-attempt environment —
    /// the askpass socket, which is re-created for every attempt — is inlined,
    /// since the shell's own environment was fixed when the tab started.
    static func sessionCommandLine(_ cmd: SSHCommand) -> String {
        let perAttempt = cmd.environment.filter { $0.key != "TERM" }
        guard !perAttempt.isEmpty else { return cmd.command }
        return "env \(envAssignments(perAttempt)) \(cmd.command)"
    }

    /// `K=V K=V` in a stable order, shell-quoted.
    static func envAssignments(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellSingleQuote($0.value))" }
            .joined(separator: " ")
    }

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

    static func clientNames(for kind: TerminalSessionKind, sftpClient: SFTPClient) -> Set<String> {
        switch kind {
        case .ssh:
            return [URL(fileURLWithPath: SSHCommandBuilder.sshBinary).lastPathComponent]
        case .sftp:
            // Derived from the client's own path: repathing a client would
            // otherwise silently break detection, and detection is what decides
            // whether keystrokes reach the terminal.
            return [
                URL(fileURLWithPath: sftpClient.binaryPath).lastPathComponent,
                URL(fileURLWithPath: SSHCommandBuilder.sshBinary).lastPathComponent,
            ]
        }
    }

    /// Wrap `inner` so it runs as: `$SHELL -l -c '<askpass env> exec <inner>'`.
    ///
    /// macOS apps launched by launchd have a minimal env. The login-shell wrap
    /// sources the user's profile, restoring SSH_AUTH_SOCK, PATH, etc.
    static func wrapInLoginShell(_ inner: String, askpassEnv: [String: String]) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let envPrefix = envAssignments(askpassEnv)
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

    static func bundledHelperPath() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/quay-askpass")
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
