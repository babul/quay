import Foundation
import SwiftData

/// Builds the app-wide `ModelContainer`.
///
/// Store lives at `~/Library/Application Support/<bundleID>/Quay.store`.
/// CloudKit sync is intentionally off in v0.1 (PRD §9 — opt-in candidate
/// for v1.x); the schema contains zero plaintext secrets either way.
@MainActor
enum PersistenceContainer {
    static let shared: ModelContainer = make()

    private static func make() -> ModelContainer {
        let schema = Schema([Folder.self, ConnectionProfile.self])
        do {
            let storeURL = try storeLocation()
            let config = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    /// Returns the on-disk store URL, creating intermediate directories.
    ///
    /// The folder is derived from the bundle identifier so Debug
    /// (`com.montopolis.quay.debug`) and Release (`com.montopolis.quay`)
    /// maintain separate stores and cannot corrupt each other's schema.
    static func storeLocation() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = Bundle.main.bundleIdentifier ?? "com.montopolis.quay"
        let dir = appSupport.appending(path: folder, directoryHint: .isDirectory)
        // One-time migration from the legacy hardcoded "Quay" folder (pre-isolation).
        let legacyDir = appSupport.appending(path: "Quay", directoryHint: .isDirectory)
        let legacyStore = legacyDir.appending(path: "Quay.store", directoryHint: .notDirectory)
        let newStore = dir.appending(path: "Quay.store", directoryHint: .notDirectory)
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
