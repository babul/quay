import Foundation
import SwiftData
import Testing
@testable import Quay

@Suite("Persistence", .serialized)
@MainActor
struct PersistenceTests {

    /// Build an isolated in-memory ModelContainer for each test so we don't
    /// stomp on the real on-disk store or on each other.
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Folder.self, ConnectionProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("folder + child folder + child connection round-trip through the store")
    func folderHierarchyRoundTrip() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext

        let root = Folder(name: "Root")
        let prod = Folder(name: "prod", parent: root, sortIndex: 0)
        let staging = Folder(name: "staging", parent: root, sortIndex: 1)
        let conn = ConnectionProfile(
            name: "web-1",
            hostname: "web1.prod.example.com",
            username: "deploy",
            authMethod: .sshAgent,
            sortIndex: 0,
            parent: prod
        )
        ctx.insert(root)
        ctx.insert(prod)
        ctx.insert(staging)
        ctx.insert(conn)
        try ctx.save()

        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        let connections = try ctx.fetch(FetchDescriptor<ConnectionProfile>())
        #expect(folders.count == 3)
        #expect(connections.count == 1)

        let fetchedRoot = try #require(folders.first(where: { $0.name == "Root" }))
        #expect(fetchedRoot.children.map(\.name).sorted() == ["prod", "staging"])

        let fetchedProd = try #require(folders.first(where: { $0.name == "prod" }))
        #expect(fetchedProd.connections.map(\.name) == ["web-1"])
    }

    @Test("sortIndex preserves order across reordering")
    func sortIndexPreserved() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let root = Folder(name: "Root")
        let names = ["c", "a", "b"]
        for (i, n) in names.enumerated() {
            ctx.insert(ConnectionProfile(
                name: n, hostname: "h", sortIndex: i, parent: root
            ))
        }
        ctx.insert(root)
        try ctx.save()

        let connections = try ctx.fetch(
            FetchDescriptor<ConnectionProfile>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        #expect(connections.map(\.name) == names)
    }

    @Test("ConnectionProfile.auth reconstructs SSHAuth correctly for each method")
    func authReconstruction() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext

        let cases: [(ConnectionProfile.AuthMethod, ConnectionProfile, SSHAuth?)] = [
            (.sshAgent,
             ConnectionProfile(name: "a", hostname: "h", authMethod: .sshAgent),
             .sshAgent),
            (.privateKey,
             ConnectionProfile(name: "b", hostname: "h",
                               authMethod: .privateKey, privateKeyPath: "/k"),
             .privateKey(path: "/k")),
            (.privateKeyWithPassphrase,
             ConnectionProfile(name: "c", hostname: "h",
                               authMethod: .privateKeyWithPassphrase,
                               secretRef: "keychain://q/x", privateKeyPath: "/k"),
             .privateKeyWithPassphrase(path: "/k", passphraseRef: "keychain://q/x")),
            (.password,
             ConnectionProfile(name: "d", hostname: "h",
                               authMethod: .password, secretRef: "keychain://q/y"),
             .password(passwordRef: "keychain://q/y")),
            (.sshConfigAlias,
             ConnectionProfile(name: "e", hostname: "ignored",
                               authMethod: .sshConfigAlias, sshConfigAlias: "alias-z"),
             .sshConfigAlias(alias: "alias-z"))
        ]

        for (method, profile, expected) in cases {
            ctx.insert(profile)
            #expect(profile.authMethod == method)
            #expect(profile.auth == expected)
        }
    }

    @Test("auth returns nil when required fields are missing")
    func authPartialFailure() {
        // privateKey without path -> nil
        let p1 = ConnectionProfile(name: "x", hostname: "h", authMethod: .privateKey)
        #expect(p1.auth == nil)

        // password without ref -> nil
        let p2 = ConnectionProfile(name: "x", hostname: "h", authMethod: .password)
        #expect(p2.auth == nil)

        // alias without alias -> nil
        let p3 = ConnectionProfile(name: "x", hostname: "h", authMethod: .sshConfigAlias)
        #expect(p3.auth == nil)
    }

    @Test("sshTarget propagates host/user/port and embeds the auth")
    func sshTargetComposition() {
        let p = ConnectionProfile(
            name: "n",
            hostname: "host.example.com",
            port: 2222,
            username: "alice",
            authMethod: .privateKey,
            privateKeyPath: "/keys/id",
            remoteTerminalType: .vt100
        )
        let t = p.sshTarget
        #expect(t?.hostname == "host.example.com")
        #expect(t?.port == 2222)
        #expect(t?.username == "alice")
        #expect(t?.auth == .privateKey(path: "/keys/id"))
        #expect(t?.remoteTerminalType == .vt100)
    }

    @Test("remote terminal type defaults and ignores invalid stored values")
    func remoteTerminalTypeDefaultAndInvalidFallback() {
        let profile = ConnectionProfile(name: "n", hostname: "h")
        #expect(profile.remoteTerminalType == .xterm256Color)
        #expect(profile.remoteTerminalTypeRaw == "xterm-256color")

        profile.remoteTerminalTypeRaw = "not-a-term"
        #expect(profile.remoteTerminalType == .xterm256Color)

        profile.remoteTerminalType = .xtermGhostty
        #expect(profile.remoteTerminalTypeRaw == "xterm-ghostty")
    }

    @Test("appearance metadata round-trips through ConnectionProfile")
    func appearanceMetadataRoundTrip() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let profile = ConnectionProfile(
            name: "n",
            hostname: "h",
            colorTag: "blue",
            iconName: "server.rack"
        )
        ctx.insert(profile)
        try ctx.save()

        let fetched = try #require(try ctx.fetch(FetchDescriptor<ConnectionProfile>()).first)
        #expect(fetched.colorTag == "blue")
        #expect(fetched.iconName == "server.rack")
    }

    @Test("login script steps round-trip through ConnectionProfile")
    func loginScriptStepsRoundTrip() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let profile = ConnectionProfile(
            name: "n",
            hostname: "h",
            loginScriptSteps: [
                LoginScriptStep(match: ":~#", send: "su - babul", sortIndex: 0),
                LoginScriptStep(match: "Password:", send: "opensesame", sortIndex: 1)
            ]
        )
        ctx.insert(profile)
        try ctx.save()

        let fetched = try #require(try ctx.fetch(FetchDescriptor<ConnectionProfile>()).first)
        #expect(fetched.loginScriptSteps.map(\.match) == [":~#", "Password:"])
        #expect(fetched.loginScriptSteps.map(\.send) == ["su - babul", "opensesame"])
        #expect(fetched.loginScriptSteps.map(\.sortIndex) == [0, 1])
    }

    @Test("login script steps normalize empty rows and order")
    func loginScriptStepsNormalizeEmptyRowsAndOrder() {
        let profile = ConnectionProfile(name: "n", hostname: "h")
        profile.loginScriptSteps = [
            LoginScriptStep(match: "  second  ", send: "  two  ", sortIndex: 2),
            LoginScriptStep(match: "", send: "ignored", sortIndex: 0),
            LoginScriptStep(match: "first", send: "one", sortIndex: 1),
            LoginScriptStep(match: "ignored", send: "   ", sortIndex: 3)
        ]

        #expect(profile.loginScriptSteps.map(\.match) == ["first", "second"])
        #expect(profile.loginScriptSteps.map(\.send) == ["one", "two"])
        #expect(profile.loginScriptSteps.map(\.sortIndex) == [0, 1])
    }

    @Test("default Hosts folder is created once")
    func defaultHostsFolderCreatedOnce() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext

        let first = try FolderStore.ensureDefaultFolder(in: ctx)
        let second = try FolderStore.ensureDefaultFolder(in: ctx)

        #expect(first.id == second.id)

        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.map(\.name) == [FolderStore.defaultFolderName])
    }

    @Test("bootstrap moves ungrouped connections into Hosts")
    func bootstrapMovesUngroupedConnectionsIntoHosts() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let prod = Folder(name: "Prod")
        let ungrouped = ConnectionProfile(name: "ungrouped", hostname: "h")
        let assigned = ConnectionProfile(name: "assigned", hostname: "h", parent: prod)
        ctx.insert(prod)
        ctx.insert(ungrouped)
        ctx.insert(assigned)
        try ctx.save()

        try FolderStore.bootstrapDefaultFolder(in: ctx)

        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        let hosts = try #require(folders.first { $0.name == FolderStore.defaultFolderName })
        #expect(ungrouped.parent?.id == hosts.id)
        #expect(assigned.parent?.id == prod.id)
    }

    @Test("unique folder name increments suffix")
    func uniqueFolderNameIncrementsSuffix() {
        let names = Set(["New Folder", "New Folder 2", "Prod"])
        let next = FolderStore.uniqueFolderName(
            baseName: "New Folder",
            existingNames: names
        )
        #expect(next == "New Folder 3")
    }

    @Test("unique connection copy name increments suffix")
    func uniqueConnectionCopyNameIncrementsSuffix() {
        let names = Set(["Prod", "Prod Copy", "Prod Copy 2"])
        let next = FolderStore.uniqueConnectionCopyName(
            baseName: "Prod",
            existingNames: names
        )
        #expect(next == "Prod Copy 3")
    }

    @Test("duplicate connection copies fields and appends to same folder")
    func duplicateConnectionCopiesFieldsAndAppendsToSameFolder() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let prod = Folder(name: "Prod")
        let stage = Folder(name: "Stage")
        let original = ConnectionProfile(
            name: "web",
            hostname: "web.example.com",
            port: 2222,
            username: "deploy",
            authMethod: .privateKeyWithPassphrase,
            secretRef: "keychain://quay/web",
            privateKeyPath: "/Users/example/.ssh/id_ed25519",
            sshConfigAlias: "web-alias",
            remoteTerminalType: .xtermColor,
            colorTag: "blue",
            iconName: "server.rack",
            notes: "production host",
            loginScriptSteps: [
                LoginScriptStep(match: ":~#", send: "whoami", sortIndex: 0)
            ],
            sortIndex: 0,
            parent: prod
        )
        let existingCopy = ConnectionProfile(
            name: "web Copy",
            hostname: "other.example.com",
            sortIndex: 1,
            parent: prod
        )
        let otherFolderCopy = ConnectionProfile(
            name: "web Copy 2",
            hostname: "stage.example.com",
            parent: stage
        )
        ctx.insert(prod)
        ctx.insert(stage)
        ctx.insert(original)
        ctx.insert(existingCopy)
        ctx.insert(otherFolderCopy)
        try ctx.save()

        let duplicate = try FolderStore.duplicateConnection(original, in: ctx)

        #expect(duplicate.id != original.id)
        #expect(duplicate.name == "web Copy 2")
        #expect(duplicate.hostname == original.hostname)
        #expect(duplicate.port == original.port)
        #expect(duplicate.username == original.username)
        #expect(duplicate.authMethodRaw == original.authMethodRaw)
        #expect(duplicate.secretRef == original.secretRef)
        #expect(duplicate.privateKeyPath == original.privateKeyPath)
        #expect(duplicate.sshConfigAlias == original.sshConfigAlias)
        #expect(duplicate.remoteTerminalType == original.remoteTerminalType)
        #expect(duplicate.colorTag == original.colorTag)
        #expect(duplicate.iconName == original.iconName)
        #expect(duplicate.notes == original.notes)
        #expect(duplicate.loginScriptSteps == original.loginScriptSteps)
        #expect(duplicate.parent?.id == prod.id)
        #expect(duplicate.sortIndex == 2)
    }
}
