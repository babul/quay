import Foundation
import SwiftData
import Testing
@testable import Quay

@Suite("SettingsBundle", .serialized)
@MainActor
struct SettingsBundleTests {

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Folder.self, ConnectionProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private static func makePassword(_ s: String) -> SensitiveBytes {
        SensitiveBytes(Data(s.utf8))
    }

    // MARK: - 1. Plaintext round-trip

    @Test("Plaintext round-trip preserves folder hierarchy and connection fields")
    func plaintextRoundTrip() throws {
        let src = try Self.makeContainer()
        let srcCtx = src.mainContext

        let root = Folder(name: "Work", sortIndex: 0)
        let child = Folder(name: "Prod", iconName: "server.rack", parent: root, sortIndex: 0)
        let conn = ConnectionProfile(
            name: "web-1",
            hostname: "web1.prod.example.com",
            port: 2222,
            username: "deploy",
            authMethod: .sshAgent,
            notes: "primary web server",
            sortIndex: 0,
            parent: child
        )
        srcCtx.insert(root)
        srcCtx.insert(child)
        srcCtx.insert(conn)
        try srcCtx.save()

        let bundleData = try SettingsBundle.encode(modelContext: srcCtx, password: nil)

        let dst = try Self.makeContainer()
        let dstCtx = dst.mainContext
        let summary = try SettingsBundle.decode(data: bundleData, modelContext: dstCtx, password: nil)

        #expect(summary.foldersAdded == 2)
        #expect(summary.connectionsAdded == 1)

        let folders = try dstCtx.fetch(FetchDescriptor<Folder>())
        let rootImported = try #require(folders.first(where: { $0.parent == nil }))
        #expect(rootImported.name == "Work")

        let childImported = try #require(rootImported.children.first)
        #expect(childImported.name == "Prod")
        #expect(childImported.iconName == "server.rack")

        let connImported = try #require(childImported.connections.first)
        #expect(connImported.name == "web-1")
        #expect(connImported.hostname == "web1.prod.example.com")
        #expect(connImported.port == 2222)
        #expect(connImported.username == "deploy")
        #expect(connImported.notes == "primary web server")
    }

    // MARK: - 2. Encrypted round-trip

    @Test("Encrypted round-trip: payload differs from plaintext, decodes correctly")
    func encryptedRoundTrip() throws {
        let src = try Self.makeContainer()
        let srcCtx = src.mainContext
        let folder = Folder(name: "Servers", sortIndex: 0)
        let conn = ConnectionProfile(name: "db", hostname: "db.example.com", sortIndex: 0, parent: folder)
        srcCtx.insert(folder)
        srcCtx.insert(conn)
        try srcCtx.save()

        let pw = Self.makePassword("correct-horse")
        let encryptedData = try SettingsBundle.encode(modelContext: srcCtx, password: pw)
        let plaintextData = try SettingsBundle.encode(modelContext: srcCtx, password: nil)

        #expect(encryptedData != plaintextData)

        // payload field must be a base64 string (JSON contains a quoted string for payload)
        let encryptedJSON = String(data: encryptedData, encoding: .utf8) ?? ""
        #expect(encryptedJSON.contains("\"encryption\""))
        #expect(!encryptedJSON.contains("\"Servers\"")) // name must not be visible in ciphertext

        let dst = try Self.makeContainer()
        let dstCtx = dst.mainContext
        let summary = try SettingsBundle.decode(data: encryptedData, modelContext: dstCtx, password: pw)

        #expect(summary.foldersAdded == 1)
        #expect(summary.connectionsAdded == 1)
        let folders = try dstCtx.fetch(FetchDescriptor<Folder>())
        #expect(folders.first?.name == "Servers")
    }

    // MARK: - 3. Wrong password

    @Test("Wrong password throws wrongPassword")
    func wrongPassword() throws {
        let src = try Self.makeContainer()
        let conn = ConnectionProfile(name: "x", hostname: "h", sortIndex: 0, parent: nil)
        src.mainContext.insert(conn)
        try src.mainContext.save()

        let data = try SettingsBundle.encode(modelContext: src.mainContext, password: Self.makePassword("right"))
        let dst = try Self.makeContainer()

        #expect(throws: SettingsBundle.BundleError.wrongPassword) {
            try SettingsBundle.decode(data: data, modelContext: dst.mainContext, password: Self.makePassword("wrong"))
        }
    }

    // MARK: - 4. Tampered ciphertext

    @Test("One flipped byte in ciphertext → wrongPassword")
    func tamperedCiphertext() throws {
        let src = try Self.makeContainer()
        let conn = ConnectionProfile(name: "c", hostname: "h", sortIndex: 0, parent: nil)
        src.mainContext.insert(conn)
        try src.mainContext.save()

        let pw = Self.makePassword("pw")
        let data = try SettingsBundle.encode(modelContext: src.mainContext, password: pw)

        // Decode JSON to find and tamper the payload base64 string
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadB64 = try #require(json["payload"] as? String)
        var payloadBytes = try #require(Data(base64Encoded: payloadB64))
        payloadBytes[0] ^= 0xFF
        json["payload"] = payloadBytes.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json)

        let dst = try Self.makeContainer()
        #expect(throws: SettingsBundle.BundleError.wrongPassword) {
            try SettingsBundle.decode(data: tampered, modelContext: dst.mainContext, password: pw)
        }
    }

    // MARK: - 5. Tampered salt → wrong key → auth failure

    @Test("Tampered salt in encrypted envelope → wrongPassword")
    func tamperedSalt() throws {
        let src = try Self.makeContainer()
        let conn = ConnectionProfile(name: "c", hostname: "h", sortIndex: 0, parent: nil)
        src.mainContext.insert(conn)
        try src.mainContext.save()

        let pw = Self.makePassword("pw")
        let data = try SettingsBundle.encode(modelContext: src.mainContext, password: pw)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var encInfo = try #require(json["encryption"] as? [String: Any])
        let saltB64 = try #require(encInfo["salt"] as? String)
        var saltBytes = try #require(Data(base64Encoded: saltB64))
        saltBytes[0] ^= 0xFF
        encInfo["salt"] = saltBytes.base64EncodedString()
        json["encryption"] = encInfo
        let tampered = try JSONSerialization.data(withJSONObject: json)

        let dst = try Self.makeContainer()
        #expect(throws: SettingsBundle.BundleError.wrongPassword) {
            try SettingsBundle.decode(data: tampered, modelContext: dst.mainContext, password: pw)
        }
    }

    // MARK: - 6. Unsupported version (plaintext)

    @Test("formatVersion above supported → unsupportedVersion error")
    func unsupportedVersion() throws {
        let src = try Self.makeContainer()
        let data = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["formatVersion"] = 99
        let patched = try JSONSerialization.data(withJSONObject: json)

        let dst = try Self.makeContainer()
        #expect(throws: SettingsBundle.BundleError.unsupportedVersion(found: 99)) {
            try SettingsBundle.decode(data: patched, modelContext: dst.mainContext, password: nil)
        }
    }

    // MARK: - 7. Malformed JSON

    @Test("Garbage bytes → malformedFile")
    func malformedJSON() throws {
        let dst = try Self.makeContainer()
        #expect(throws: SettingsBundle.BundleError.malformedFile) {
            try SettingsBundle.decode(data: Data("not a bundle".utf8), modelContext: dst.mainContext, password: nil)
        }
    }

    // MARK: - 8. Cyclic folder graph

    @Test("Cyclic folder parent references → cyclicFolderGraph")
    func cyclicFolderGraph() throws {
        let idA = UUID()
        let idB = UUID()
        let payload: [String: Any] = [
            "folders": [
                ["id": idA.uuidString, "name": "A", "sortIndex": 0, "parentID": idB.uuidString],
                ["id": idB.uuidString, "name": "B", "sortIndex": 1, "parentID": idA.uuidString]
            ],
            "connections": [] as [[String: Any]]
        ]
        let envelope: [String: Any] = [
            "magic": SettingsBundle.magic,
            "formatVersion": SettingsBundle.formatVersion,
            "exportedAt": "2026-01-01T00:00:00Z",
            "encryption": NSNull(),
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let dst = try Self.makeContainer()
        #expect(throws: SettingsBundle.BundleError.cyclicFolderGraph) {
            try SettingsBundle.decode(data: data, modelContext: dst.mainContext, password: nil)
        }
    }

    // MARK: - 9. Collision uniquing on import

    @Test("Imported folder with same name gets uniqued")
    func folderCollisionUniquing() throws {
        let dst = try Self.makeContainer()
        let dstCtx = dst.mainContext

        // Pre-populate with "Servers" root folder
        let existing = Folder(name: "Servers", sortIndex: 0)
        dstCtx.insert(existing)
        try dstCtx.save()

        // Bundle that also has "Servers" root folder
        let src = try Self.makeContainer()
        let folder = Folder(name: "Servers", sortIndex: 0)
        src.mainContext.insert(folder)
        try src.mainContext.save()

        let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)
        try SettingsBundle.decode(data: bundleData, modelContext: dstCtx, password: nil)

        let folderNames = Set(try dstCtx.fetch(FetchDescriptor<Folder>()).map(\.name))
        #expect(folderNames.contains("Servers"))
        #expect(folderNames.contains("Servers 2"))
    }

    @Test("Imported connection placed in default folder gets uniqued on name collision")
    func connectionCollisionUniquing() throws {
        let dst = try Self.makeContainer()
        let dstCtx = dst.mainContext

        // Pre-populate the default "Hosts" folder with a "web" connection
        let existing = Folder(name: "Hosts", sortIndex: 0)
        let existingConn = ConnectionProfile(name: "web", hostname: "web.example.com", sortIndex: 0, parent: existing)
        dstCtx.insert(existing)
        dstCtx.insert(existingConn)
        try dstCtx.save()

        // Bundle: a connection with no parent (orphan → placed in ensureDefaultFolder = "Hosts")
        let src = try Self.makeContainer()
        let orphan = ConnectionProfile(name: "web", hostname: "other.example.com", sortIndex: 0, parent: nil)
        src.mainContext.insert(orphan)
        try src.mainContext.save()

        let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)
        try SettingsBundle.decode(data: bundleData, modelContext: dstCtx, password: nil)

        let connNames = Set(try dstCtx.fetch(FetchDescriptor<ConnectionProfile>()).map(\.name))
        #expect(connNames.contains("web"))
        #expect(connNames.contains("web Copy"))
    }

    // MARK: - 10. Empty database

    @Test("Empty database round-trip yields (0, 0) summary")
    func emptyRoundTrip() throws {
        let src = try Self.makeContainer()
        let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)

        let dst = try Self.makeContainer()
        let summary = try SettingsBundle.decode(data: bundleData, modelContext: dst.mainContext, password: nil)
        #expect(summary.foldersAdded == 0)
        #expect(summary.connectionsAdded == 0)
    }

    // MARK: - 11. secretRef opaque pass-through

    @Test("secretRef URI survives round-trip byte-for-byte")
    func secretRefPassThrough() throws {
        let src = try Self.makeContainer()
        let folder = Folder(name: "F", sortIndex: 0)
        let conn = ConnectionProfile(
            name: "c",
            hostname: "h",
            authMethod: .password,
            secretRef: "keychain://io.github.babul.quay/my-server",
            sortIndex: 0,
            parent: folder
        )
        src.mainContext.insert(folder)
        src.mainContext.insert(conn)
        try src.mainContext.save()

        let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)
        let dst = try Self.makeContainer()
        try SettingsBundle.decode(data: bundleData, modelContext: dst.mainContext, password: nil)

        let imported = try dst.mainContext.fetch(FetchDescriptor<ConnectionProfile>())
        #expect(imported.first?.secretRef == "keychain://io.github.babul.quay/my-server")
    }

    // MARK: - 12. loginScriptStepsJSON opaque pass-through

    // MARK: - Preferences round-trip

    private static let preferenceKeys = [
        AppDefaultsKeys.showTabColorBars,
        AppDefaultsKeys.confirmCloseActiveSessions,
        SFTPClient.defaultsKey,
        AppDefaultsKeys.sftpDefaultLocalDirectory,
    ]

    private static func preservingPreferences(_ body: () throws -> Void) rethrows {
        let saved = preferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try body()
    }

    @Test("Preferences are encoded and restored on import")
    func preferencesRoundTrip() throws {
        try Self.preservingPreferences {
            let src = try Self.makeContainer()

            UserDefaults.standard.set(false, forKey: AppDefaultsKeys.showTabColorBars)
            UserDefaults.standard.set(false, forKey: AppDefaultsKeys.confirmCloseActiveSessions)
            UserDefaults.standard.set("lftp", forKey: SFTPClient.defaultsKey)
            UserDefaults.standard.set("/tmp/sftp-test", forKey: AppDefaultsKeys.sftpDefaultLocalDirectory)

            let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)

            for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }

            let dst = try Self.makeContainer()
            try SettingsBundle.decode(data: bundleData, modelContext: dst.mainContext, password: nil)

            #expect(UserDefaults.standard.object(forKey: AppDefaultsKeys.showTabColorBars) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: AppDefaultsKeys.confirmCloseActiveSessions) as? Bool == false)
            #expect(UserDefaults.standard.string(forKey: SFTPClient.defaultsKey) == "lftp")
            #expect(UserDefaults.standard.string(forKey: AppDefaultsKeys.sftpDefaultLocalDirectory) == "/tmp/sftp-test")
        }
    }

    @Test("Preferences missing from source don't clobber existing values")
    func preferencesNotClobbedWhenAbsent() throws {
        try Self.preservingPreferences {
            let src = try Self.makeContainer()

            for key in Self.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
            let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)

            UserDefaults.standard.set(true, forKey: AppDefaultsKeys.showTabColorBars)
            UserDefaults.standard.set(true, forKey: AppDefaultsKeys.confirmCloseActiveSessions)

            let dst = try Self.makeContainer()
            try SettingsBundle.decode(data: bundleData, modelContext: dst.mainContext, password: nil)

            #expect(UserDefaults.standard.object(forKey: AppDefaultsKeys.showTabColorBars) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: AppDefaultsKeys.confirmCloseActiveSessions) as? Bool == true)
        }
    }

    @Test("Bundle without preferences field decodes cleanly")
    func oldBundleWithoutPreferences() throws {
        try Self.preservingPreferences {
            let legacyJSON = """
            {
                "magic": "quay.bundle",
                "formatVersion": 1,
                "exportedAt": "2025-01-01T00:00:00Z",
                "payload": { "folders": [], "connections": [] }
            }
            """
            let data = Data(legacyJSON.utf8)
            let dst = try Self.makeContainer()

            UserDefaults.standard.set(true, forKey: AppDefaultsKeys.showTabColorBars)

            try SettingsBundle.decode(data: data, modelContext: dst.mainContext, password: nil)

            #expect(UserDefaults.standard.object(forKey: AppDefaultsKeys.showTabColorBars) as? Bool == true)
        }
    }

    @Test("loginScriptStepsJSON is not re-normalized on import")
    func loginScriptStepsPassThrough() throws {
        let src = try Self.makeContainer()
        let folder = Folder(name: "F", sortIndex: 0)
        let conn = ConnectionProfile(name: "c", hostname: "h", sortIndex: 0, parent: folder)
        // Set raw JSON with trailing space — the normalizedLoginScriptSteps setter would strip it
        let rawJSON = #"[{"id":"00000000-0000-0000-0000-000000000001","match":"Password: ","send":"hunter2","sortIndex":0}]"#
        conn.loginScriptStepsJSON = rawJSON
        src.mainContext.insert(folder)
        src.mainContext.insert(conn)
        try src.mainContext.save()

        let bundleData = try SettingsBundle.encode(modelContext: src.mainContext, password: nil)
        let dst = try Self.makeContainer()
        try SettingsBundle.decode(data: bundleData, modelContext: dst.mainContext, password: nil)

        let imported = try dst.mainContext.fetch(FetchDescriptor<ConnectionProfile>())
        #expect(imported.first?.loginScriptStepsJSON == rawJSON)
    }
}
