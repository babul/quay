import Testing
@testable import Quay

@Suite("ConnectionProbe argv")
struct ConnectionProbeArgvTests {

    // MARK: - Helpers

    private func hasPair(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        for i in 0 ..< (argv.count - 1) where argv[i] == flag && argv[i + 1] == value {
            return true
        }
        return false
    }

    private func hasOption(_ argv: [String], _ kv: String) -> Bool {
        hasPair(argv, "-o", kv)
    }

    // MARK: - sshAgent

    @Test("sshAgent: BatchMode=yes, NumberOfPasswordPrompts=0, correct host token")
    func agentFlags() {
        let target = SSHTarget(hostname: "host.example", port: nil, username: "alice", auth: .sshAgent)
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(argv.first == "/usr/bin/ssh")
        #expect(argv.last == "exit 0")
        #expect(hasOption(argv, "BatchMode=yes"))
        #expect(hasOption(argv, "ConnectTimeout=5"))
        #expect(hasOption(argv, "StrictHostKeyChecking=accept-new"))
        #expect(hasOption(argv, "NumberOfPasswordPrompts=0"))
        #expect(argv.contains("alice@host.example"))
        #expect(!hasPair(argv, "-p", ""))
    }

    @Test("sshAgent: port flag emitted when set")
    func agentWithPort() {
        let target = SSHTarget(hostname: "h", port: 2222, username: nil, auth: .sshAgent)
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(hasPair(argv, "-p", "2222"))
        #expect(argv.contains("h"))
        #expect(!argv.contains { $0.contains("@") })
    }

    @Test("sshAgent: no port flag when port is nil")
    func agentNoPort() {
        let target = SSHTarget(hostname: "h", port: nil, username: nil, auth: .sshAgent)
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(!argv.contains("-p"))
    }

    // MARK: - privateKey

    @Test("privateKey: adds -i and IdentitiesOnly=yes, keeps BatchMode=yes")
    func privateKeyFlags() {
        let target = SSHTarget(hostname: "h", port: nil, username: "bob",
                               auth: .privateKey(path: "/home/bob/.ssh/id_ed25519"))
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(hasPair(argv, "-i", "/home/bob/.ssh/id_ed25519"))
        #expect(hasOption(argv, "IdentitiesOnly=yes"))
        #expect(hasOption(argv, "BatchMode=yes"))
        #expect(hasOption(argv, "NumberOfPasswordPrompts=0"))
        #expect(argv.last == "exit 0")
    }

    // MARK: - privateKeyWithPassphrase

    @Test("privateKeyWithPassphrase: no BatchMode=yes, NumberOfPasswordPrompts=1")
    func privateKeyPPFlags() {
        let target = SSHTarget(hostname: "h", port: nil, username: nil,
                               auth: .privateKeyWithPassphrase(path: "/k", passphraseRef: "keychain://s/a"))
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(!hasOption(argv, "BatchMode=yes"))
        #expect(hasOption(argv, "NumberOfPasswordPrompts=1"))
        #expect(hasPair(argv, "-i", "/k"))
        #expect(hasOption(argv, "IdentitiesOnly=yes"))
        #expect(argv.last == "exit 0")
    }

    // MARK: - password

    @Test("password: PreferredAuthentications, PubkeyAuthentication=no, no BatchMode=yes")
    func passwordFlags() {
        let target = SSHTarget(hostname: "h", port: nil, username: nil,
                               auth: .password(passwordRef: "keychain://s/a"))
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(!hasOption(argv, "BatchMode=yes"))
        #expect(hasOption(argv, "NumberOfPasswordPrompts=1"))
        #expect(hasOption(argv, "PreferredAuthentications=password,keyboard-interactive"))
        #expect(hasOption(argv, "PubkeyAuthentication=no"))
        #expect(argv.last == "exit 0")
    }

    // MARK: - sshConfigAlias

    @Test("sshConfigAlias: bare alias, no -p, no user@, BatchMode=yes")
    func aliasFlags() {
        let target = SSHTarget(hostname: "ignored", port: 9999, username: "ignored",
                               auth: .sshConfigAlias(alias: "prod-server"))
        let argv = ConnectionProbe.probeArgv(for: target)
        #expect(argv.contains("prod-server"))
        #expect(!argv.contains("-p"))
        #expect(!argv.contains { $0.contains("@") })
        #expect(hasOption(argv, "BatchMode=yes"))
        #expect(argv.last == "exit 0")
    }

    // MARK: - probeEnv

    @Test("probeEnv: empty when askpass is nil")
    func envNil() {
        #expect(ConnectionProbe.probeEnv(askpass: nil).isEmpty)
    }

    @Test("probeEnv: installs all four SSH_ASKPASS keys")
    func envAskpass() {
        let ap = SSHCommandBuilder.AskpassEnv(helperPath: "/helper", socketPath: "/sock")
        let env = ConnectionProbe.probeEnv(askpass: ap)
        #expect(env["SSH_ASKPASS"] == "/helper")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["DISPLAY"] == ":0")
        #expect(env["QUAY_ASKPASS_SOCKET"] == "/sock")
    }
}
