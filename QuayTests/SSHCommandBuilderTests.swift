import Testing
@testable import Quay

@Suite("SSHCommandBuilder")
struct SSHCommandBuilderTests {

    // MARK: ssh-agent (no secrets)

    @Test("agent + bare hostname")
    func agentBareHost() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "example.com", port: nil, username: nil, auth: .sshAgent)
        )
        #expect(cmd.command == "/usr/bin/ssh -o BatchMode=no example.com")
        #expect(cmd.environment == ["TERM": "xterm-256color"])
    }

    @Test("agent + user + non-default port")
    func agentUserPort() {
        let cmd = SSHCommandBuilder.build(
            SSHTarget(hostname: "host.internal", port: 2222, username: "deploy", auth: .sshAgent)
        )
        #expect(cmd.command == "/usr/bin/ssh -o BatchMode=no -p 2222 deploy@host.internal")
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
        #expect(cmd.command == "/usr/bin/ssh -o BatchMode=no prod-bastion")
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
}
