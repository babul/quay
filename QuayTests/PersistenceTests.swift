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
            privateKeyPath: "/keys/id"
        )
        let t = p.sshTarget
        #expect(t?.hostname == "host.example.com")
        #expect(t?.port == 2222)
        #expect(t?.username == "alice")
        #expect(t?.auth == .privateKey(path: "/keys/id"))
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
}
