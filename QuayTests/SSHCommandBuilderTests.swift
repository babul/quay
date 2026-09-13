import Foundation
import Testing
@testable import Quay

@Suite("SSHCommandBuilder")
struct SSHCommandBuilderTests {
    /// Pinned once, below, so the per-case assertions stay about what varies.
    private let common = SSHCommandBuilder.commonOptionArguments.joined(separator: " ")

    @Test("Every session carries the connect timeout and keepalives, in a stable order")
    func commonOptions() {
        #expect(
            SSHCommandBuilder.commonOptionArguments == [
                "-o", "BatchMode=no",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveCountMax=3",
                "-o", "ServerAliveInterval=15",
            ]
        )
    }


    // MARK: ssh-agent (no secrets)

    @Test("agent + bare hostname")
    func agentBareHost() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "example.com", port: nil, username: nil, auth: .sshAgent)
        )
        #expect(cmd.command == "/usr/bin/ssh \(common) example.com")
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    @Test("agent + user + non-default port")
    func agentUserPort() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "host.internal", port: 2222, username: "deploy", auth: .sshAgent)
        )
        #expect(cmd.command == "/usr/bin/ssh \(common) -p 2222 deploy@host.internal")
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    // MARK: Identity file

    @Test("private key path with no passphrase")
    func keyNoPassphrase() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(
                hostname: "h",
                port: nil,
                username: "u",
                auth: .privateKey(path: "/Users/me/.ssh/id_ed25519")
            )
        )
        #expect(cmd.command.contains("-i /Users/me/.ssh/id_ed25519"))
        #expect(cmd.command.contains("-o IdentitiesOnly=yes"))
        #expect(cmd.command.hasSuffix(" u@h"))
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    @Test("private key path containing spaces is quoted")
    func keyPathQuoted() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(
                hostname: "h",
                port: nil,
                username: nil,
                auth: .privateKey(path: "/Users/me/My Keys/id")
            )
        )
        #expect(cmd.command.contains("'/Users/me/My Keys/id'"))
    }

    // MARK: Password / passphrase auth wires askpass env

    @Test("password auth without askpass info: only TERM env")
    func passwordNoAskpass() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "h", port: nil, username: "u",
                      auth: .password(passwordRef: "keychain://quay/h"))
        )
        #expect(cmd.environment == ["TERM": "xterm-256color"])
        #expect(cmd.command.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(cmd.command.contains("PubkeyAuthentication=no"))
    }

    @Test("password auth with askpass info: env + flags")
    func passwordWithAskpass() {
        let askpass = SSHCommandBuilder.AskpassEnv(
            helperPath: "/Apps/Quay.app/Contents/MacOS/quay-askpass",
            socketPath: "/tmp/quay-askpass-abc.sock"
        )
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "h", port: nil, username: "u",
                      auth: .password(passwordRef: "keychain://quay/h")),
            askpass: askpass
        )
        #expect(cmd.environment["TERM"] == "xterm-256color")
        #expect(cmd.environment["SSH_ASKPASS"] == askpass.helperPath)
        #expect(cmd.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(cmd.environment["DISPLAY"] == ":0")
        #expect(cmd.environment["QUAY_ASKPASS_SOCKET"] == askpass.socketPath)
    }

    @Test("private key + passphrase wires askpass env")
    func passphraseAuth() {
        let askpass = SSHCommandBuilder.AskpassEnv(
            helperPath: "/p/quay-askpass",
            socketPath: "/tmp/q.sock"
        )
        let cmd = SSHCommandBuilder.build(
            SSHTarget(
                hostname: "h", port: nil, username: nil,
                auth: .privateKeyWithPassphrase(
                    path: "/k",
                    passphraseRef: "keychain://quay/k-pass"
                )
            ),
            askpass: askpass
        )
        #expect(cmd.environment["TERM"] == "xterm-256color")
        #expect(cmd.environment["SSH_ASKPASS"] == "/p/quay-askpass")
        #expect(cmd.command.contains("-i /k"))
    }

    @Test("remote terminal type is emitted as TERM")
    func remoteTerminalTypeEnv() {
        for type in RemoteTerminalType.allCases {
            let cmd = SSHCommandBuilder.build(
                SSHTarget(
                    hostname: "h",
                    port: nil,
                    username: nil,
                    auth: .sshAgent,
                    remoteTerminalType: type
                )
            )
            #expect(cmd.environment["TERM"] == type.rawValue)
        }
    }

    // MARK: ssh-config alias

    @Test("ssh.config alias: argv is just the alias")
    func configAlias() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "ignored", port: nil, username: nil,
                      auth: .sshConfigAlias(alias: "prod-bastion"))
        )
        #expect(cmd.command == "/usr/bin/ssh \(common) prod-bastion")
    }

    @Test("alias with non-trivial chars is quoted")
    func aliasQuoted() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "h", port: nil, username: nil,
                      auth: .sshConfigAlias(alias: "my host"))
        )
        #expect(cmd.command.contains("'my host'"))
    }

    // MARK: extraOptions

    @Test("extraOptions are emitted in deterministic order")
    func extraOptionsOrder() {
        var t = SSHTarget(hostname: "h", port: nil, username: nil, auth: .sshAgent)
        t.extraOptions = ["ServerAliveInterval": "30", "ConnectTimeout": "5"]
        let cmd = SSHCommandBuilder.build(t)
        // Sorted by key: ConnectTimeout, ServerAliveInterval
        let connectIdx = cmd.command.range(of: "ConnectTimeout=5")!
        let aliveIdx = cmd.command.range(of: "ServerAliveInterval=30")!
        #expect(connectIdx.lowerBound < aliveIdx.lowerBound)
    }

    // MARK: SFTP

    @Test("sftp agent + user + non-default port")
    func sftpAgentUserPort() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "host.internal", port: 2222, username: "deploy", auth: .sshAgent)
        )
        #expect(cmd.command == "/usr/bin/sftp \(common) -P 2222 deploy@host.internal")
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    @Test("homebrew OpenSSH sftp uses Homebrew binary")
    func homebrewOpenSSHSFTPBinary() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "host.internal", port: nil, username: nil, auth: .sshAgent),
            client: .homebrewOpenSSH
        )
        #expect(cmd.command == "/opt/homebrew/bin/sftp \(common) host.internal")
    }

    @Test("sftp private key path containing spaces is quoted")
    func sftpKeyPathQuoted() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(
                hostname: "h",
                port: nil,
                username: nil,
                auth: .privateKey(path: "/Users/me/My Keys/id")
            )
        )
        #expect(cmd.command.contains("'/Users/me/My Keys/id'"))
        #expect(cmd.command.contains("-o IdentitiesOnly=yes"))
    }

    @Test("sftp password auth with askpass info wires env")
    func sftpPasswordWithAskpass() {
        let askpass = SSHCommandBuilder.AskpassEnv(
            helperPath: "/Apps/Quay.app/Contents/MacOS/quay-askpass",
            socketPath: "/tmp/quay-askpass-abc.sock"
        )
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "h", port: nil, username: "u",
                      auth: .password(passwordRef: "keychain://quay/h")),
            askpass: askpass
        )
        #expect(cmd.environment["SSH_ASKPASS"] == askpass.helperPath)
        #expect(cmd.environment["QUAY_ASKPASS_SOCKET"] == askpass.socketPath)
        #expect(cmd.command.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(cmd.command.contains("PubkeyAuthentication=no"))
    }

    @Test("sftp config alias uses alias destination")
    func sftpConfigAlias() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "ignored", port: nil, username: nil,
                      auth: .sshConfigAlias(alias: "prod-bastion"))
        )
        #expect(cmd.command == "/usr/bin/sftp \(common) prod-bastion")
    }

    @Test("sftp remote directory is appended to destination and quoted")
    func sftpRemoteDirectory() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(
                hostname: "host.internal",
                port: nil,
                username: "deploy",
                auth: .sshAgent,
                remoteDirectory: "/var/www/site assets/"
            )
        )
        #expect(cmd.command == "/usr/bin/sftp \(common) 'deploy@host.internal:/var/www/site assets/'")
    }

    @Test("sftp IPv6 destination brackets host when remote directory is set")
    func sftpIPv6RemoteDirectory() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(
                hostname: "2001:db8::1",
                port: nil,
                username: "deploy",
                auth: .sshAgent,
                remoteDirectory: "/srv"
            )
        )
        #expect(cmd.command == "/usr/bin/sftp \(common) 'deploy@[2001:db8::1]:/srv'")
    }

    @Test("lftp uses lftp binary and OpenSSH connect program")
    func lftpClientCommand() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(
                hostname: "host.internal",
                port: 2222,
                username: "deploy",
                auth: .sshAgent
            ),
            client: .lftp
        )
        #expect(cmd.command.hasPrefix("/opt/homebrew/bin/lftp -e "))
        #expect(cmd.command.contains("set color:use-color yes"))
        #expect(cmd.command.contains("set color:dir-colors"))
        #expect(cmd.command.contains("di=01;34"))
        #expect(cmd.command.contains("alias ls cls"))
        #expect(cmd.command.contains("set sftp:connect-program"))
        #expect(!cmd.command.contains("--user"))
        #expect(cmd.command.contains("/usr/bin/ssh -a -x \(common) -l deploy -p 2222"))
        #expect(cmd.command.hasSuffix(" sftp://host.internal"))
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    @Test("lftp encodes remote directory in URL")
    func lftpRemoteDirectory() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(
                hostname: "host.internal",
                port: nil,
                username: "deploy",
                auth: .sshAgent,
                remoteDirectory: "/var/www/site assets/"
            ),
            client: .lftp
        )
        #expect(!cmd.command.contains("--user"))
        #expect(cmd.command.contains("-l deploy"))
        #expect(cmd.command.hasSuffix(" sftp://host.internal/var/www/site%20assets/"))
    }

    @Test("lftp password auth wires askpass and password-only ssh options")
    func lftpPasswordWithAskpass() {
        let askpass = SSHCommandBuilder.AskpassEnv(
            helperPath: "/p/quay-askpass",
            socketPath: "/tmp/q.sock"
        )
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "h", port: nil, username: "u",
                      auth: .password(passwordRef: "keychain://quay/h")),
            askpass: askpass,
            client: .lftp
        )
        #expect(cmd.environment["SSH_ASKPASS"] == "/p/quay-askpass")
        #expect(cmd.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(cmd.environment["QUAY_ASKPASS_SOCKET"] == "/tmp/q.sock")
        #expect(cmd.command.contains("set color:use-color yes"))
        #expect(cmd.command.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(cmd.command.contains("PubkeyAuthentication=no"))
        #expect(!cmd.command.contains("--user"))
        #expect(cmd.command.contains("-l u"))
        #expect(cmd.command.hasSuffix(" sftp://h"))
    }
}

/// The tab's pty runs a host shell for its whole life and sessions are typed
/// into it — that is what lets a reconnect continue on the same screen. These
/// pin the two strings that make it work.
@Suite("Session host shell")
struct SessionHostShellTests {
    @Test("The host shell loads the user's environment, then hands over quietly")
    func hostShellCommand() {
        let command = SessionBootstrap.hostShellCommand()
        // A login shell first: a launchd-started app otherwise lacks
        // SSH_AUTH_SOCK and PATH.
        #expect(command.contains(" -l -c "))
        // Then a bare shell with no visible prompt and no startup file.
        #expect(command.contains("PS1="))
        // Echo off and the line editor disabled, so Quay's typed command never
        // reaches the screen — the session announces itself instead.
        #expect(command.contains("stty -echo"))
        #expect(command.contains("+o emacs"))
        // The prompt clears the modes a dead remote left behind — without the
        // bracketed-paste reset, the next command Quay types arrives wrapped in
        // ESC[200~ and the shell runs "00~/usr/bin/ssh".
        #expect(SessionBootstrap.hostShellPrompt.contains("\u{1B}[?2004l"))
        // Never the alt-screen reset: it restores a saved cursor, which sends
        // the cursor home and makes the next session overwrite the scrollback.
        #expect(!SessionBootstrap.hostShellPrompt.contains("1049"))
        #expect(command.contains("?2004l"))
        #expect(command.contains("ENV="))
        #expect(command.contains("/bin/sh -i"))
    }

    @Test("A session with no per-attempt environment is typed bare")
    func plainCommandLine() {
        let cmd = SSHCommand(command: "/usr/bin/ssh host", environment: ["TERM": "xterm-256color"])
        // TERM is set on the host shell once, so it never appears on screen.
        #expect(SessionBootstrap.sessionCommandLine(cmd) == "/usr/bin/ssh host")
    }

    @Test("Per-attempt askpass plumbing is inlined, since the socket changes each try")
    func commandLineInlinesAskpass() {
        let cmd = SSHCommand(
            command: "/usr/bin/ssh host",
            environment: [
                "TERM": "xterm-256color",
                "SSH_ASKPASS": "/tmp/quay askpass.sock",
                "SSH_ASKPASS_REQUIRE": "force",
            ]
        )
        #expect(
            SessionBootstrap.sessionCommandLine(cmd)
                == "env SSH_ASKPASS='/tmp/quay askpass.sock' SSH_ASKPASS_REQUIRE='force' /usr/bin/ssh host"
        )
    }

    @Test("Each session kind knows which client to look for in the pty")
    func clientNames() {
        #expect(SessionBootstrap.clientNames(for: .ssh, sftpClient: .macOSOpenSSH) == ["ssh"])
        #expect(SessionBootstrap.clientNames(for: .sftp, sftpClient: .macOSOpenSSH).contains("sftp"))
        #expect(SessionBootstrap.clientNames(for: .sftp, sftpClient: .lftp).contains("lftp"))
    }

    @Test("A session announces itself in place of the command it runs")
    func announcesSession() {
        let line = SessionBootstrap.announced(
            "/usr/bin/ssh host",
            marker: "→ ssh babul@host  (attempt 2)"
        )
        // %s, not interpolation: a target containing % would otherwise be read
        // as a format specifier.
        #expect(line.hasPrefix("printf '\\033[2m%s\\033[0m\\n' "))
        #expect(line.contains("'→ ssh babul@host  (attempt 2)'"))
        #expect(line.hasSuffix("; /usr/bin/ssh host"))
    }

    /// ssh takes the first value of a repeated `-o`, so a per-profile override
    /// only works if it is emitted ahead of Quay's defaults.
    @Test("A per-profile option overrides Quay's default of the same key")
    func extraOptionsWinOverDefaults() {
        var target = SSHTarget(hostname: "host", auth: .sshAgent)
        target.extraOptions = ["ConnectTimeout": "60"]
        let command = SSHCommandBuilder.build(target).command

        let mine = try? #require(command.range(of: "ConnectTimeout=60"))
        let theirs = try? #require(command.range(of: "ConnectTimeout=\(SSHCommandBuilder.connectTimeoutSeconds)"))
        #expect(mine!.lowerBound < theirs!.lowerBound)
    }

    @MainActor
    @Test("The session watch's connected-assumption follows the connect timeout")
    func assumeConnectedFollowsTimeout() {
        #expect(
            TerminalTabItem.assumeConnectedAfter
                > TimeInterval(SSHCommandBuilder.connectTimeoutSeconds)
        )
    }

    @Test("The marker is timestamped, and names the attempt only when retrying")
    func markerFormat() {
        let when = Date(timeIntervalSince1970: 1_773_380_712)  // 2026-03-13 12:25:12 UTC
        let first = SessionBootstrap.sessionMarker(target: "ssh babul@host", attempt: 0, at: when)

        #expect(first.hasPrefix("→ "))
        #expect(first.hasSuffix("  ssh babul@host"))
        // yyyy-MM-dd HH:mm:ss, so it sorts and greps.
        let stamp = first.dropFirst(2).prefix(19)
        #expect(stamp.count == 19)
        #expect(stamp.contains("-") && stamp.contains(":"))
    }

    @Test("A retry marker reports the backoff it waited out")
    func markerReportsBackoff() {
        let when = Date(timeIntervalSince1970: 1_773_380_712)
        let retry = SessionBootstrap.sessionMarker(
            target: "ssh babul@host",
            attempt: 5,
            backoff: 15,
            at: when
        )
        #expect(retry.hasSuffix("  ssh babul@host  (attempt 5 · waited 15s)"))

        // A retry that skipped the wait (Space, Cmd-R) claims no wait.
        let immediate = SessionBootstrap.sessionMarker(
            target: "ssh babul@host",
            attempt: 2,
            backoff: 0,
            at: when
        )
        #expect(immediate.hasSuffix("  ssh babul@host  (attempt 2)"))
    }

    @Test("An alias profile's marker names the alias, which is what runs")
    func aliasMarkerNamesTheAlias() {
        let alias = SSHTarget(
            hostname: "prod-bastion",
            username: "ignored",
            auth: .sshConfigAlias(alias: "prod-bastion")
        )
        // The command is `ssh prod-bastion`; announcing ignored@prod-bastion
        // would name something the command never mentions.
        #expect(SessionBootstrap.displayTarget(for: alias, kind: .ssh) == "ssh prod-bastion")
    }

    @Test("The marker names the client and target, with or without a username")
    func displayTarget() {
        let withUser = SSHTarget(hostname: "host", username: "babul", auth: .sshAgent)
        #expect(SessionBootstrap.displayTarget(for: withUser, kind: .ssh) == "ssh babul@host")
        #expect(SessionBootstrap.displayTarget(for: withUser, kind: .sftp) == "sftp babul@host")

        let noUser = SSHTarget(hostname: "host", auth: .sshAgent)
        #expect(SessionBootstrap.displayTarget(for: noUser, kind: .ssh) == "ssh host")
    }
}
