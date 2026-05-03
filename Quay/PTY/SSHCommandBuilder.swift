import Foundation

/// Authentication strategy for an SSH connection.
///
/// Each case maps to a specific shape of `ssh(1)` argv plus, for cases that
/// need a secret, a `SecretReference` URI the resolver consumes at connect
/// time. The builder NEVER sees plaintext — it only assembles argv + env.
enum SSHAuth: Sendable, Equatable {
    /// Use the running ssh-agent. No secret material handled by Quay.
    case sshAgent
    /// Identity file at `path` with no passphrase (or passphrase already
    /// loaded into the agent via `ssh-add`).
    case privateKey(path: String)
    /// Identity file at `path` whose passphrase comes from `passphraseRef`.
    case privateKeyWithPassphrase(path: String, passphraseRef: String)
    /// Password authentication; password from `passwordRef`.
    case password(passwordRef: String)
    /// Delegate everything to `~/.ssh/config` (`Host alias { … }`). The host,
    /// user, port, identity, ProxyJump etc. all come from there.
    case sshConfigAlias(alias: String)
}

/// Connection-level SSH inputs the builder consumes.
///
/// Mirrors the subset of `ConnectionProfile` (added in Step 5) that the
/// builder cares about. Keeping a separate struct lets us unit-test the
/// builder without dragging SwiftData in.
struct SSHTarget: Sendable, Equatable {
    var hostname: String
    var port: Int?
    var username: String?
    var auth: SSHAuth
    /// Extra `-o key=value` overrides appended verbatim. Reserved; v0.1
    /// leaves this empty.
    var extraOptions: [String: String] = [:]
}

/// Output of `SSHCommandBuilder.build`.
struct SSHCommand: Sendable, Equatable {
    /// Single shell-parseable command line for `ghostty_surface_config_s.command`.
    var command: String
    /// Environment variables to inject into the spawned process. Populated
    /// only when a secret reference needs the askpass helper.
    var environment: [String: String]
}

/// Pure function: `(SSHTarget, askpass info) -> SSHCommand`.
///
/// The resulting command string drives `/usr/bin/ssh` directly. The
/// environment dict carries `SSH_ASKPASS_*` plumbing for password and
/// passphrase auth — the actual askpass server is owned by Step 6.
enum SSHCommandBuilder {
    /// Plumbing the builder needs from Step 6 to wire up `SSH_ASKPASS`.
    /// `nil` means no askpass plumbing is added (every auth that requires
    /// a secret will fall through to interactive prompting).
    struct AskpassEnv: Sendable, Equatable {
        /// Absolute path to the bundled `quay-askpass` helper.
        var helperPath: String
        /// Per-connection Unix domain socket the helper connects to.
        var socketPath: String
    }

    static let sshBinary = "/usr/bin/ssh"

    static func build(_ target: SSHTarget, askpass: AskpassEnv? = nil) -> SSHCommand {
        var argv: [String] = [sshBinary]
        var env: [String: String] = [:]

        // Common flags. `BatchMode=no` makes sure ssh asks for prompts via
        // the askpass helper rather than failing silently.
        argv.append(contentsOf: ["-o", "BatchMode=no"])

        // TEMPORARY: -v so we can diagnose why known_hosts lookups
        // differ between Quay-spawned ssh and the user's terminal.
        // Remove once host-key prompts are resolved.
        argv.append("-v")

        switch target.auth {
        case .sshAgent:
            argv.append(contentsOf: hostFlags(target))

        case .privateKey(let path):
            argv.append(contentsOf: ["-i", path])
            argv.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
            argv.append(contentsOf: hostFlags(target))

        case .privateKeyWithPassphrase(let path, _):
            argv.append(contentsOf: ["-i", path])
            argv.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
            argv.append(contentsOf: hostFlags(target))
            installAskpass(askpass, into: &env)

        case .password(_):
            // Disable pubkey so ssh prompts via askpass.
            argv.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            argv.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
            argv.append(contentsOf: hostFlags(target))
            installAskpass(askpass, into: &env)

        case .sshConfigAlias(let alias):
            // Everything else is in ~/.ssh/config; we just append the alias.
            argv.append(alias)
            // The alias may use a key with a passphrase or a password —
            // wire askpass anyway so secrets flow if requested.
            installAskpass(askpass, into: &env)
        }

        for (k, v) in target.extraOptions.sorted(by: { $0.key < $1.key }) {
            argv.append(contentsOf: ["-o", "\(k)=\(v)"])
        }

        return SSHCommand(
            command: argv.map(shellQuote).joined(separator: " "),
            environment: env
        )
    }

    private static func hostFlags(_ target: SSHTarget) -> [String] {
        var out: [String] = []
        if let port = target.port {
            out.append(contentsOf: ["-p", String(port)])
        }
        let userPrefix = target.username.map { "\($0)@" } ?? ""
        out.append("\(userPrefix)\(target.hostname)")
        return out
    }

    private static func installAskpass(_ a: AskpassEnv?, into env: inout [String: String]) {
        guard let a else { return }
        env["SSH_ASKPASS"] = a.helperPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"   // OpenSSH ignores the value but requires it set
        env["QUAY_ASKPASS_SOCKET"] = a.socketPath
    }
}

/// Single-quote a shell argument when it contains anything other than
/// safe characters. Inside single quotes only the single quote itself
/// needs escaping (`'` → `'\''`).
@inline(__always)
private func shellQuote(_ arg: String) -> String {
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyz" +
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
        "0123456789" +
        "@%+=:,./-_"
    )
    if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return arg
    }
    let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
