import Foundation
import SwiftData

/// Builds the app-wide `ModelContainer`.
///
/// Two separate SQLite stores:
///   • `Quay.store`     — hosts/folders (ConnectionProfile, Folder). Always local.
///   • `Snippets.store` — snippet groups + snippets (SnippetGroup, Snippet).
///     Currently local (cloudKitDatabase: .none). To enable iCloud sync for snippets,
///     flip snippetsConfig to .private("iCloud.io.github.babul.quay.snippets") and add
///     the CloudKit entitlement + container in the Apple Developer portal.
///
/// CloudKit sync is intentionally off in v0.1 (PRD §9 — opt-in candidate
/// for v1.x); the schema contains zero plaintext secrets either way.
@MainActor
enum PersistenceContainer {
    static let shared: ModelContainer = make()

    private static func make() -> ModelContainer {
        let mainSchema     = Schema([Folder.self, ConnectionProfile.self])
        let snippetsSchema = Schema([SnippetGroup.self, Snippet.self])
        do {
            let mainConfig = ModelConfiguration(
                "Quay",
                schema: mainSchema,
                url: try storeLocation(),
                cloudKitDatabase: .none
            )
            let snippetsConfig = ModelConfiguration(
                "Snippets",
                schema: snippetsSchema,
                url: try snippetsStoreLocation(),
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: Folder.self, ConnectionProfile.self, SnippetGroup.self, Snippet.self,
                configurations: mainConfig, snippetsConfig
            )
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    /// Returns the URL for the snippets store, creating intermediate directories.
    static func snippetsStoreLocation() throws -> URL {
        let dir = try storeLocation().deletingLastPathComponent()
        return dir.appending(path: "Snippets.store", directoryHint: .notDirectory)
    }

    /// Returns the on-disk store URL, creating intermediate directories.
    ///
    /// The folder is derived from the bundle identifier so Debug
    /// (`io.github.babul.quay.debug`) and Release (`io.github.babul.quay`)
    /// maintain separate stores and cannot corrupt each other's schema.
    static func storeLocation() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = Bundle.main.bundleIdentifier ?? "io.github.babul.quay"
        let dir = appSupport.appending(path: folder, directoryHint: .isDirectory)
        let newStore = dir.appending(path: "Quay.store", directoryHint: .notDirectory)
        // Migration 1: legacy hardcoded "Quay" folder (pre-isolation).
        let legacyDir = appSupport.appending(path: "Quay", directoryHint: .isDirectory)
        let legacyStore = legacyDir.appending(path: "Quay.store", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: legacyStore.path),
           !FileManager.default.fileExists(atPath: newStore.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-shm", "-wal"] {
                let src = legacyDir.appending(path: "Quay.store\(suffix)")
                let dst = dir.appending(path: "Quay.store\(suffix)")
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.moveItem(at: src, to: dst)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return newStore
    }
}
