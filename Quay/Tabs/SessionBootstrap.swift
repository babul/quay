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

    /// Build a `GhosttySurfaceConfig` + optional `AskpassServer` for `profile`.
    ///
    /// The caller is responsible for calling `askpass.stop()` when the tab closes
    /// (NOT on reconnect — the server must outlive the surface for re-auth).
    static func start(
        for profile: ConnectionProfile,
        kind: TerminalSessionKind = .ssh,
        localDirectoryOverride: String? = nil
    ) throws -> (config: GhosttySurfaceConfig, askpass: AskpassServer?) {
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
        cfg.command = wrapInLoginShell(cmd.command, askpassEnv: cmd.environment)
        if kind == .sftp {
            cfg.workingDirectory = normalizedLocalDirectory(localDirectoryOverride)
                ?? normalizedLocalDirectory(target.localDirectory)
                ?? defaultLocalDirectory()
        }
        cfg.environment = [:]
        cfg.waitAfterCommand = true
        cfg.scaleFactor = NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
        return (cfg, askpass)
    }

    /// Wrap `inner` so it runs as: `$SHELL -l -c '<askpass env> exec <inner>'`.
    ///
    /// macOS apps launched by launchd have a minimal env. The login-shell wrap
    /// sources the user's profile, restoring SSH_AUTH_SOCK, PATH, etc.
    static func wrapInLoginShell(_ inner: String, askpassEnv: [String: String]) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let envPrefix = askpassEnv
            .sorted(by: { $0.key < $1.key })
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
