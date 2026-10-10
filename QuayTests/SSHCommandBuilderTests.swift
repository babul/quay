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

    /// lftp's shipped defaults wait 5 minutes for a reply and then retry 1000
    /// times, which at an interactive prompt is indistinguishable from a hang:
    /// a dead host produced a command that simply never returned, and nothing
    /// on screen or in the tab said why.
    @Test("lftp is told to give up on a dead host rather than retry forever")
    func lftpReportsADeadHost() {
        let cmd = SSHCommandBuilder.buildSFTP(
            SSHTarget(hostname: "host.internal", auth: .sshAgent),
            client: .lftp
        )
        for setting in SSHCommandBuilder.lftpInteractiveTimeouts {
            #expect(cmd.command.contains(setting))
        }
        // Near ssh's own ServerAliveInterval * ServerAliveCountMax, so lftp
        // gives up on roughly the same evidence its transport does.
        #expect(cmd.command.contains("set net:timeout 15"))
        // Bounded, where the default 1000 is not.
        #expect(cmd.command.contains("set net:max-retries 3"))
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

/// The tab's pty runs `quay-supervisor` for its whole life and sessions are
/// spawned through it — that is what lets a reconnect continue on the same
/// screen.
@Suite("Session supervisor")
struct SessionSupervisorTests {
    @Test("The supervisor is reached through the user's login shell")
    func supervisorCommand() {
        let command = SessionBootstrap.wrapInLoginShell("'/Applications/Quay.app/Contents/MacOS/quay-supervisor'", environment: [:])
        // A login shell first: a launchd-started app otherwise lacks
        // SSH_AUTH_SOCK and PATH, and every session inherits them from the
        // supervisor — which then replaces the shell rather than running under it.
        #expect(command.contains(" -l -c "))
        #expect(command.contains("exec "))
        #expect(command.contains("quay-supervisor"))
    }

    @Test("An sftp session is spawned in its local directory")
    func sftpSpawnsInLocalDirectory() throws {
        let profile = ConnectionProfile(name: "p", hostname: "h", username: "u")
        let session = try SessionBootstrap.start(
            for: profile,
            kind: .sftp,
            localDirectoryOverride: NSTemporaryDirectory(),
            sftpClient: .macOSOpenSSH
        )
        #expect(session.spawn.workingDirectory == SessionBootstrap.normalizedLocalDirectory(NSTemporaryDirectory()))
        #expect(session.spawn.argv.first == SFTPClient.macOSOpenSSH.binaryPath)
        #expect(session.spawn.environment["TERM"] == "xterm-256color")
        // The marker is the tab's to add: it knows the attempt number.
        #expect(session.spawn.announce == nil)
    }

    @Test("An ssh session carries no working directory of its own")
    func sshSpawnsWherever() throws {
        let profile = ConnectionProfile(name: "p", hostname: "h", username: "u")
        let session = try SessionBootstrap.start(for: profile, kind: .ssh)
        #expect(session.spawn.workingDirectory == nil)
        #expect(session.spawn.argv.first == SSHCommandBuilder.sshBinary)
    }

    /// lftp prints its own prompt and doesn't open a transport until the first
    /// command, so waiting for a socket would report "connecting" over a prompt
    /// the user is already typing into. OpenSSH's sftp connects eagerly, so its
    /// TCP state is the honest signal, as for ssh.
    ///
    /// Takes the client explicitly: `SFTPClient.preferred` is the test host's
    /// saved setting, which differs between machines.
    @Test("An sftp session counts as connected once its client is running, if it outlives its transport",
          arguments: SFTPClient.allCases)
    func sftpIsConnectedWhenClientRuns(client: SFTPClient) throws {
        let profile = ConnectionProfile(name: "p", hostname: "h", username: "u")
        let sftp = try SessionBootstrap.start(for: profile, kind: .sftp, sftpClient: client)
        let ssh = try SessionBootstrap.start(for: profile, kind: .ssh, sftpClient: client)

        #expect(sftp.connectedWhenClientRuns == (client == .lftp))
        // ssh shows nothing until its connection is up, whatever the sftp client.
        #expect(!ssh.connectedWhenClientRuns)
    }

    @Test("The marker is written dimmed, so it reads as a note and not output")
    func announcementIsDimmed() {
        let line = SessionBootstrap.announcement("→ ssh babul@host  (attempt 2)")
        #expect(line == "\u{1B}[2m→ ssh babul@host  (attempt 2)\u{1B}[0m")
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
