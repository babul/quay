import Foundation
import SwiftData

@MainActor
enum FolderStore {
    static let defaultFolderName = "Hosts"

    static func topLevelFolders(in context: ModelContext) throws -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.parent == nil },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    static func ensureDefaultFolder(in context: ModelContext) throws -> Folder {
        let folders = try topLevelFolders(in: context)
        if let existing = folders.first(where: { $0.name == defaultFolderName }) {
            return existing
        }

        let folder = Folder(
            name: defaultFolderName,
            sortIndex: nextFolderSortIndex(from: folders)
        )
        context.insert(folder)
        try context.save()
        return folder
    }

    static func bootstrapDefaultFolder(in context: ModelContext) throws {
        let folder = try ensureDefaultFolder(in: context)
        try moveUngroupedConnections(to: folder, in: context)
    }

    static func moveUngroupedConnections(to folder: Folder, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate { $0.parent == nil },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        let connections = try context.fetch(descriptor)
        guard !connections.isEmpty else { return }

        let nextIndex = (folder.connections.map(\.sortIndex).max() ?? -1) + 1
        for (offset, connection) in connections.enumerated() {
            connection.parent = folder
            connection.sortIndex = nextIndex + offset
        }
        try context.save()
    }

    static func nextFolderSortIndex(from folders: [Folder]) -> Int {
        (folders.map(\.sortIndex).max() ?? -1) + 1
    }

    static func nextConnectionSortIndex(in folder: Folder) -> Int {
        (folder.connections.map(\.sortIndex).max() ?? -1) + 1
    }

    static func uniqueFolderName(baseName: String, existingNames: Set<String>) -> String {
        uniqueName(base: baseName, existingNames: existingNames)
    }

    static func uniqueConnectionCopyName(baseName: String, existingNames: Set<String>) -> String {
        uniqueName(base: "\(baseName) Copy", existingNames: existingNames)
    }

    @discardableResult
    static func saveSSHConfigHost(
        _ host: DiscoveredSSHHost,
        in context: ModelContext
    ) throws -> ConnectionProfile {
        let folder = try ensureDefaultFolder(in: context)
        let existingNames = Set(folder.connections.map(\.name))
        let profile = ConnectionProfile(
            name: uniqueConnectionName(
                baseName: host.displayName,
                existingNames: existingNames
            ),
            hostname: host.alias,
            authMethod: .sshConfigAlias,
            sshConfigAlias: host.alias,
            sortIndex: nextConnectionSortIndex(in: folder),
            parent: folder
        )
        context.insert(profile)
        try context.save()
        return profile
    }

    private static func uniqueConnectionName(baseName: String, existingNames: Set<String>) -> String {
        uniqueName(base: baseName, existingNames: existingNames)
    }

    private static func uniqueName(base: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(base) else { return base }
        var index = 2
        while existingNames.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    @discardableResult
    static func duplicateConnection(
        _ profile: ConnectionProfile,
        in context: ModelContext
    ) throws -> ConnectionProfile {
        let folder = try profile.parent ?? ensureDefaultFolder(in: context)
        let existingNames = Set(folder.connections.map(\.name))
        let duplicate = ConnectionProfile(
            name: uniqueConnectionCopyName(
                baseName: profile.name,
                existingNames: existingNames
            ),
            hostname: profile.hostname,
            port: profile.port,
            username: profile.username,
            authMethod: profile.authMethod ?? .sshAgent,
            secretRef: profile.secretRef,
            privateKeyPath: profile.privateKeyPath,
            sshConfigAlias: profile.sshConfigAlias,
            localDirectory: profile.localDirectory,
            remoteDirectory: profile.remoteDirectory,
            remoteTerminalType: profile.remoteTerminalType,
            colorTag: profile.colorTag,
            iconName: profile.iconName,
            notes: profile.notes,
            loginScriptSteps: profile.loginScriptSteps,
            sortIndex: nextConnectionSortIndex(in: folder),
            parent: folder
        )
        duplicate.authMethodRaw = profile.authMethodRaw
        context.insert(duplicate)
        try context.save()
        return duplicate
    }
}
