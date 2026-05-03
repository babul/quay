import Foundation
import SwiftData

/// Builds the app-wide `ModelContainer`.
///
/// Store lives at `~/Library/Application Support/Quay/Quay.store`.
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
    static func storeLocation() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appending(path: "Quay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir.appending(path: "Quay.store", directoryHint: .notDirectory)
    }
}
