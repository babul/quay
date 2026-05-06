import Foundation
import Testing
@testable import Quay

@Suite("SSH config host provider")
struct SSHConfigHostProviderTests {
    @Test("reads concrete host aliases from config")
    func readsConcreteHostAliases() throws {
        let root = try TemporarySSHConfigDirectory()
        let config = root.url.appending(path: "config")
        try """
        # Global defaults
        Host *
          ForwardAgent yes

        Host prod-web stage-db
          User deploy

        Host *.example.com !blocked-host one?two
          User ignored
        """.write(to: config, atomically: true, encoding: .utf8)

        let hosts = SSHConfigHostProvider.loadHosts(rootConfigURL: config)

        #expect(hosts.map(\.alias) == ["prod-web", "stage-db"])
        #expect(hosts.allSatisfy { $0.sourceFile == config.path })
        #expect(hosts.first?.lineNumber == 5)
    }

    @Test("follows relative and absolute includes")
    func followsIncludes() throws {
        let root = try TemporarySSHConfigDirectory()
        let config = root.url.appending(path: "config")
        let includeDir = root.url.appending(path: "conf.d")
        let relativeInclude = includeDir.appending(path: "one.conf")
        let absoluteInclude = root.url.appending(path: "absolute.conf")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        try """
        Host root-host
        Include conf.d/*.conf
        Include \(absoluteInclude.path)
        """.write(to: config, atomically: true, encoding: .utf8)
        try "Host relative-host\n".write(to: relativeInclude, atomically: true, encoding: .utf8)
        try "Host absolute-host\n".write(to: absoluteInclude, atomically: true, encoding: .utf8)

        let hosts = SSHConfigHostProvider.loadHosts(rootConfigURL: config)

        #expect(hosts.map(\.alias) == ["absolute-host", "relative-host", "root-host"])
    }

    @Test("avoids include cycles and duplicate aliases")
    func avoidsCyclesAndDuplicates() throws {
        let root = try TemporarySSHConfigDirectory()
        let first = root.url.appending(path: "config")
        let second = root.url.appending(path: "extra.conf")
        try """
        Host shared first-only
        Include extra.conf
        """.write(to: first, atomically: true, encoding: .utf8)
        try """
        Host shared second-only
        Include config
        """.write(to: second, atomically: true, encoding: .utf8)

        let hosts = SSHConfigHostProvider.loadHosts(rootConfigURL: first)

        #expect(hosts.map(\.alias) == ["first-only", "second-only", "shared"])
    }

    @Test("stable IDs are based on alias")
    func stableIDsAreBasedOnAlias() {
        let first = DiscoveredSSHHost(alias: "Prod-Web", sourceFile: "/tmp/a")
        let second = DiscoveredSSHHost(alias: "prod-web", sourceFile: "/tmp/b")

        #expect(first.id == second.id)
    }
}

private struct TemporarySSHConfigDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "quay-ssh-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
