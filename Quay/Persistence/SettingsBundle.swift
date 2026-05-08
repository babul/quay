import CryptoKit
import Foundation
import SwiftData

// MARK: - DTOs

private struct FolderDTO: Codable {
    let id: UUID
    let name: String
    let iconName: String?
    let sortIndex: Int
    let parentID: UUID?
}

private struct ConnectionDTO: Codable {
    let id: UUID
    let name: String
    let hostname: String
    let port: Int?
    let username: String?
    let authMethodRaw: String
    let secretRef: String?
    let privateKeyPath: String?
    let sshConfigAlias: String?
    let localDirectory: String?
    let remoteDirectory: String?
    let remoteTerminalTypeRaw: String?
    let colorTag: String?
    let iconName: String?
    let notes: String?
    let loginScriptStepsJSON: String?
    let sortIndex: Int
    let parentFolderID: UUID?
}

private struct PreferencesDTO: Codable {
    let showTabColorBars: Bool?
    let autoHideSidebar: Bool?
    let confirmCloseActiveSessions: Bool?
    let sftpClient: String?
    let sftpDefaultLocalDirectory: String?
    let automaticallyChecksForUpdates: Bool?
    let automaticallyDownloadsUpdates: Bool?
}

private enum UpdatesDefaultsKeys {
    static let checksForUpdates = "SUEnableAutomaticChecks"
    static let downloadsUpdates = "SUAutomaticallyUpdate"
}

private struct SnippetGroupDTO: Codable {
    let id: UUID
    let name: String
    let iconName: String?
    let sortIndex: Int
}

private struct SnippetDTO: Codable {
    let id: UUID
    let name: String
    let body: String
    let bodyRef: String?
    let notes: String?
    let appendsReturn: Bool?
    let sortIndex: Int
    let groupID: UUID?
}

private struct SettingsPayload: Codable {
    let folders: [FolderDTO]
    let connections: [ConnectionDTO]
    let preferences: PreferencesDTO?
    let snippetGroups: [SnippetGroupDTO]?
    let snippets: [SnippetDTO]?
}

struct ImportSummary {
    let foldersAdded: Int
    let connectionsAdded: Int
    let snippetGroupsAdded: Int
    let snippetsAdded: Int
}

// MARK: - Private envelope types

private struct EncryptionMetadata: Codable {
    static let algIdentifier = "AES-GCM-256"
    static let kdfIdentifier = "PBKDF2-HMAC-SHA256"

    let alg: String
    let kdf: String
    let kdfIterations: UInt32
    let salt: Data
    let nonce: Data
}

private struct EnvelopeHeader: Codable {
    let magic: String
    let formatVersion: Int
    let encryption: EncryptionMetadata?
}

private struct PlaintextEnvelope: Codable {
    let magic: String
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String?
    let payload: SettingsPayload
}

private struct EncryptedEnvelope: Codable {
    let magic: String
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String?
    let encryption: EncryptionMetadata
    let payload: Data
}

// MARK: - SettingsBundle

@MainActor
enum SettingsBundle {
    static let formatVersion = 1
    static let magic = "quay.bundle"

    enum BundleError: LocalizedError, Equatable {
        case malformedFile
        case unsupportedVersion(found: Int)
        case wrongPassword
        case missingPassword
        case cyclicFolderGraph
        /// A login-script step's Keychain value could not be read during export
        /// (e.g. Touch ID was cancelled or the entry no longer exists).
        case lockedStepResolutionFailed
        /// A secured snippet's Keychain value could not be read during export.
        case snippetSecretResolutionFailed
        /// The bundle contains Keychain-backed secrets but no password was provided.
        /// Exporting without encryption would expose plaintext secrets.
        case passwordRequiredForSecrets

        var errorDescription: String? {
            switch self {
            case .lockedStepResolutionFailed:
                return "A locked login-script step could not be read from your Keychain. Make sure Touch ID succeeds and try again."
            case .snippetSecretResolutionFailed:
                return "A secured snippet could not be read from your Keychain. Make sure Touch ID succeeds and try again."
            case .passwordRequiredForSecrets:
                return "This export contains Keychain-backed values. Set a password to protect them."
            default:
                return nil
            }
        }
    }

    // MARK: Encode

    static func encode(container: ModelContainer, password: SensitiveBytes?) throws -> Data {
        let mainCtx = ModelContext(container)
        let snippetsCtx = ModelContext(container)

        let allFolders = try mainCtx.fetch(FetchDescriptor<Folder>())
        let allConnections = try mainCtx.fetch(FetchDescriptor<ConnectionProfile>())
        let allGroups = try snippetsCtx.fetch(FetchDescriptor<SnippetGroup>())
        let allSnippets = try snippetsCtx.fetch(FetchDescriptor<Snippet>())

        let folderDTOs = allFolders.map { f in
            FolderDTO(
                id: f.id,
                name: f.name,
                iconName: f.iconName,
                sortIndex: f.sortIndex,
                parentID: f.parent?.id
            )
        }
        let connectionDTOs = try allConnections.map { c in
            ConnectionDTO(
                id: c.id,
                name: c.name,
                hostname: c.hostname,
                port: c.port,
                username: c.username,
                authMethodRaw: c.authMethodRaw,
                secretRef: c.secretRef,
                privateKeyPath: c.privateKeyPath,
                sshConfigAlias: c.sshConfigAlias,
                localDirectory: c.localDirectory,
                remoteDirectory: c.remoteDirectory,
                remoteTerminalTypeRaw: c.remoteTerminalTypeRaw,
                colorTag: c.colorTag,
                iconName: c.iconName,
                notes: c.notes,
                loginScriptStepsJSON: try exportLoginScriptStepsJSON(c.loginScriptStepsJSON),
                sortIndex: c.sortIndex,
                parentFolderID: c.parent?.id
            )
        }

        let snippetGroupDTOs = allGroups.map { g in
            SnippetGroupDTO(id: g.id, name: g.name, iconName: g.iconName, sortIndex: g.sortIndex)
        }
        let snippetDTOs = try allSnippets.map { s -> SnippetDTO in
            let resolvedBody = try resolveSnippetBody(s)
            return SnippetDTO(
                id: s.id,
                name: s.name,
                body: resolvedBody,
                bodyRef: s.bodyRef != nil ? "pending" : nil,
                notes: s.notes.isEmpty ? nil : s.notes,
                appendsReturn: s.appendsReturn,
                sortIndex: s.sortIndex,
                groupID: s.group?.id
            )
        }

        let hasSecrets = snippetDTOs.contains { $0.bodyRef != nil }
            || connectionDTOs.contains { dto in
                (try? makeDecoder().decode([LoginScriptStep].self, from: Data(dto.loginScriptStepsJSON?.utf8 ?? "[]".utf8)))?.contains { $0.sendRef != nil } ?? false
            }
        if hasSecrets, password == nil {
            throw BundleError.passwordRequiredForSecrets
        }

        let prefs = PreferencesDTO(
            showTabColorBars: UserDefaults.standard.object(forKey: AppDefaultsKeys.showTabColorBars) as? Bool,
            autoHideSidebar: UserDefaults.standard.object(forKey: AppDefaultsKeys.autoHideSidebar) as? Bool,
            confirmCloseActiveSessions: UserDefaults.standard.object(forKey: AppDefaultsKeys.confirmCloseActiveSessions) as? Bool,
            sftpClient: UserDefaults.standard.string(forKey: SFTPClient.defaultsKey),
            sftpDefaultLocalDirectory: UserDefaults.standard.string(forKey: AppDefaultsKeys.sftpDefaultLocalDirectory),
            automaticallyChecksForUpdates: UserDefaults.standard.object(forKey: UpdatesDefaultsKeys.checksForUpdates) as? Bool,
            automaticallyDownloadsUpdates: UserDefaults.standard.object(forKey: UpdatesDefaultsKeys.downloadsUpdates) as? Bool
        )
        let payload = SettingsPayload(
            folders: folderDTOs,
            connections: connectionDTOs,
            preferences: prefs,
            snippetGroups: snippetGroupDTOs,
            snippets: snippetDTOs
        )
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let enc = makeEncoder()

        if let password {
            let payloadData = try enc.encode(payload)
            var saltBytes = [UInt8](repeating: 0, count: ExportCrypto.saltLength)
            _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
            let salt = Data(saltBytes)
            let nonce = AES.GCM.Nonce()
            let nonceData = Data(nonce)
            let aad = aadData(version: formatVersion)

            let ciphertextPlusTag = try ExportCrypto.encrypt(
                plaintext: payloadData,
                password: password,
                salt: salt,
                nonce: nonce,
                aad: aad
            )
            let encMeta = EncryptionMetadata(
                alg: EncryptionMetadata.algIdentifier,
                kdf: EncryptionMetadata.kdfIdentifier,
                kdfIterations: ExportCrypto.kdfIterations,
                salt: salt,
                nonce: nonceData
            )
            let envelope = EncryptedEnvelope(
                magic: magic,
                formatVersion: formatVersion,
                exportedAt: Date(),
                appVersion: appVersion,
                encryption: encMeta,
                payload: ciphertextPlusTag
            )
            return try enc.encode(envelope)
        } else {
            let envelope = PlaintextEnvelope(
                magic: magic,
                formatVersion: formatVersion,
                exportedAt: Date(),
                appVersion: appVersion,
                payload: payload
            )
            return try enc.encode(envelope)
        }
    }

    // MARK: Decode

    @discardableResult
    static func decode(
        data: Data,
        container: ModelContainer,
        password: SensitiveBytes?
    ) throws -> ImportSummary {
        let dec = makeDecoder()

        let header: EnvelopeHeader = try mapMalformed { try dec.decode(EnvelopeHeader.self, from: data) }

        guard header.magic == magic else { throw BundleError.malformedFile }
        guard header.formatVersion <= formatVersion else {
            throw BundleError.unsupportedVersion(found: header.formatVersion)
        }

        let settingsPayload: SettingsPayload
        if let encMeta = header.encryption {
            guard let pw = password else { throw BundleError.missingPassword }
            let envelope: EncryptedEnvelope = try mapMalformed { try dec.decode(EncryptedEnvelope.self, from: data) }

            let ciphertextPlusTag = envelope.payload
            let nonce: AES.GCM.Nonce = try mapMalformed { try AES.GCM.Nonce(data: encMeta.nonce) }

            let payloadData: Data
            do {
                payloadData = try ExportCrypto.decrypt(
                    ciphertext: ciphertextPlusTag,
                    password: pw,
                    salt: encMeta.salt,
                    nonce: nonce,
                    aad: aadData(version: envelope.formatVersion)
                )
            } catch ExportCryptoError.wrongPassword {
                throw BundleError.wrongPassword
            } catch {
                throw BundleError.malformedFile
            }

            settingsPayload = try mapMalformed { try dec.decode(SettingsPayload.self, from: payloadData) }
        } else {
            let envelope: PlaintextEnvelope = try mapMalformed { try dec.decode(PlaintextEnvelope.self, from: data) }
            settingsPayload = envelope.payload
        }

        try validateNoCycles(in: settingsPayload.folders)

        let mainCtx = ModelContext(container)
        let snippetsCtx = ModelContext(container)

        let (foldersAdded, idToImported) = try insertFolders(settingsPayload.folders, into: mainCtx)
        let connectionsAdded = try insertConnections(
            settingsPayload.connections,
            idToImported: idToImported,
            into: mainCtx
        )
        try mainCtx.save()

        let (snippetGroupsAdded, groupIDMap) = try insertSnippetGroups(settingsPayload.snippetGroups ?? [], into: snippetsCtx)
        let snippetsAdded = try insertSnippets(settingsPayload.snippets ?? [], groupIDMap: groupIDMap, into: snippetsCtx)
        try snippetsCtx.save()

        applyPreferences(settingsPayload.preferences)
        return ImportSummary(
            foldersAdded: foldersAdded,
            connectionsAdded: connectionsAdded,
            snippetGroupsAdded: snippetGroupsAdded,
            snippetsAdded: snippetsAdded
        )
    }

    // MARK: - Private helpers

    private static func resolveSnippetBody(_ snippet: Snippet) throws -> String {
        guard let uri = snippet.bodyRef else { return snippet.body }
        guard let pair = SecretReference.keychainPair(forURI: uri),
              let bytes = try? KeychainStore.read(service: pair.service, account: pair.account)
        else { throw BundleError.snippetSecretResolutionFailed }
        return bytes.unsafeUTF8String() ?? ""
    }

    private static func resolveImportSnippetBody(
        dto: SnippetDTO,
        newID: UUID,
        shouldSecure: Bool
    ) throws -> (body: String, bodyRef: String?) {
        guard shouldSecure else {
            return (body: dto.body, bodyRef: nil)
        }
        do {
            try KeychainStore.write(
                service: SecretReference.snippetKeychainService,
                account: newID.uuidString,
                value: SensitiveBytes(Data(dto.body.utf8))
            )
            return (body: "", bodyRef: SecretReference.snippetURI(snippetID: newID))
        } catch {
            // Keychain write failed; store as plaintext
            return (body: dto.body, bodyRef: nil)
        }
    }

    private static func applyPreferences(_ prefs: PreferencesDTO?) {
        guard let prefs else { return }
        let defaults = UserDefaults.standard
        let setIfPresent: (Any?, String) -> Void = { value, key in
            if let value { defaults.set(value, forKey: key) }
        }
        setIfPresent(prefs.showTabColorBars, AppDefaultsKeys.showTabColorBars)
        setIfPresent(prefs.autoHideSidebar, AppDefaultsKeys.autoHideSidebar)
        setIfPresent(prefs.confirmCloseActiveSessions, AppDefaultsKeys.confirmCloseActiveSessions)
        setIfPresent(prefs.sftpClient, SFTPClient.defaultsKey)
        setIfPresent(prefs.sftpDefaultLocalDirectory, AppDefaultsKeys.sftpDefaultLocalDirectory)
        setIfPresent(prefs.automaticallyChecksForUpdates, UpdatesDefaultsKeys.checksForUpdates)
        setIfPresent(prefs.automaticallyDownloadsUpdates, UpdatesDefaultsKeys.downloadsUpdates)
    }

    private static func mapMalformed<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw BundleError.malformedFile }
    }

    private static func aadData(version: Int) -> Data {
        Data("\(magic)|v\(version)".utf8)
    }

    /// Resolves any Keychain-backed step values in `loginScriptStepsJSON` to
    /// plaintext so the exported bundle is self-contained. Bundle-level
    /// encryption is the caller's responsibility.
    ///
    /// Returns the input unchanged when it cannot be decoded or contains no
    /// locked steps.
    private static func exportLoginScriptStepsJSON(_ json: String?) throws -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              var steps = try? makeDecoder().decode([LoginScriptStep].self, from: data),
              steps.contains(where: { $0.sendRef != nil }) else {
            return json
        }

        for i in steps.indices {
            guard let uri = steps[i].sendRef else { continue }
            guard let pair = SecretReference.keychainPair(forURI: uri) else {
                throw BundleError.malformedFile
            }
            do {
                let bytes = try KeychainStore.read(service: pair.service, account: pair.account)
                steps[i].send = bytes.unsafeUTF8String() ?? ""
                steps[i].sendRef = nil
            } catch {
                throw BundleError.lockedStepResolutionFailed
            }
        }

        guard let resolved = try? makeEncoder().encode(steps),
              let resolvedJSON = String(data: resolved, encoding: .utf8) else {
            throw BundleError.malformedFile
        }
        return resolvedJSON
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dataEncodingStrategy = .base64
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func validateNoCycles(in folders: [FolderDTO]) throws {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folder in folders {
            var seen = Set<UUID>()
            var current = folder.parentID
            while let id = current {
                guard seen.insert(id).inserted else { throw BundleError.cyclicFolderGraph }
                current = byID[id]?.parentID
            }
        }
    }

    private static func insertFolders(
        _ dtos: [FolderDTO],
        into context: ModelContext
    ) throws -> (Int, [UUID: Folder]) {
        let byID = Dictionary(uniqueKeysWithValues: dtos.map { ($0.id, $0) })
        var remaining = Set(dtos.map { $0.id })
        var idToImported = [UUID: Folder]()

        var existingRoots: [Folder] = (try? context.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.parent == nil })
        )) ?? []

        while !remaining.isEmpty {
            let batch = remaining.filter { id in
                guard let dto = byID[id] else { return false }
                guard let parentID = dto.parentID else { return true }
                return idToImported[parentID] != nil || byID[parentID] == nil
            }
            guard !batch.isEmpty else { break }

            for id in batch.sorted(by: { (byID[$0]?.sortIndex ?? 0) < (byID[$1]?.sortIndex ?? 0) }) {
                guard let dto = byID[id] else { continue }
                let parent = dto.parentID.flatMap { idToImported[$0] }

                let siblings: [Folder] = parent?.children ?? existingRoots
                let existingNames = Set(siblings.map(\.name))
                let name = FolderStore.uniqueFolderName(baseName: dto.name, existingNames: existingNames)
                let nextIndex = FolderStore.nextFolderSortIndex(from: siblings)

                let folder = Folder(name: name, iconName: dto.iconName, parent: parent, sortIndex: nextIndex)
                context.insert(folder)
                idToImported[id] = folder
                remaining.remove(id)
                if parent == nil { existingRoots.append(folder) }
            }
        }
        return (idToImported.count, idToImported)
    }

    private static func insertConnections(
        _ dtos: [ConnectionDTO],
        idToImported: [UUID: Folder],
        into context: ModelContext
    ) throws -> Int {
        var nextSortIndexByFolder = [ObjectIdentifier: Int]()
        var count = 0
        for dto in dtos {
            let parent: Folder
            if let folderID = dto.parentFolderID, let imported = idToImported[folderID] {
                parent = imported
            } else {
                parent = try FolderStore.ensureDefaultFolder(in: context)
            }

            let existingNames = Set(parent.connections.map(\.name))
            let name = existingNames.contains(dto.name)
                ? FolderStore.uniqueConnectionCopyName(baseName: dto.name, existingNames: existingNames)
                : dto.name

            let secretRef: String?
            if let ref = dto.secretRef, (try? SecretReference(ref)) != nil {
                secretRef = ref
            } else {
                secretRef = nil
            }

            let folderKey = ObjectIdentifier(parent)
            let sortIdx = nextSortIndexByFolder[folderKey] ?? FolderStore.nextConnectionSortIndex(in: parent)
            nextSortIndexByFolder[folderKey] = sortIdx + 1

            let profile = ConnectionProfile(
                name: name,
                hostname: dto.hostname,
                port: dto.port,
                username: dto.username,
                secretRef: secretRef,
                privateKeyPath: dto.privateKeyPath,
                sshConfigAlias: dto.sshConfigAlias,
                localDirectory: dto.localDirectory,
                remoteDirectory: dto.remoteDirectory,
                colorTag: dto.colorTag,
                iconName: dto.iconName,
                notes: dto.notes,
                sortIndex: sortIdx,
                parent: parent
            )
            profile.authMethodRaw = dto.authMethodRaw
            profile.loginScriptStepsJSON = dto.loginScriptStepsJSON
            profile.remoteTerminalTypeRaw = dto.remoteTerminalTypeRaw
            context.insert(profile)
            count += 1
        }
        return count
    }

    private static func insertSnippetGroups(
        _ dtos: [SnippetGroupDTO],
        into context: ModelContext
    ) throws -> (Int, [UUID: SnippetGroup]) {
        let existing = (try? context.fetch(FetchDescriptor<SnippetGroup>())) ?? []
        var existingNames = Set(existing.map(\.name))
        var groupIDMap = [UUID: SnippetGroup]()
        for dto in dtos {
            let name = SnippetStore.uniqueGroupName(baseName: dto.name, existingNames: existingNames)
            let sortIdx = SnippetStore.nextGroupSortIndex(from: existing + Array(groupIDMap.values))
            let group = SnippetGroup(name: name, iconName: dto.iconName, sortIndex: sortIdx)
            context.insert(group)
            groupIDMap[dto.id] = group
            existingNames.insert(name)
        }
        return (groupIDMap.count, groupIDMap)
    }

    private static func insertSnippets(
        _ dtos: [SnippetDTO],
        groupIDMap: [UUID: SnippetGroup],
        into context: ModelContext
    ) throws -> Int {
        let existingUngrouped = (try? context.fetch(
            FetchDescriptor<Snippet>(predicate: #Predicate { $0.group == nil })
        )) ?? []
        var ungroupedNames = Set(existingUngrouped.map(\.name))
        var count = 0
        for dto in dtos {
            let group = dto.groupID.flatMap { groupIDMap[$0] }
            let existingNames = group.map { Set(($0.snippets ?? []).map(\.name)) } ?? ungroupedNames
            let name = SnippetStore.uniqueSnippetName(baseName: dto.name, existingNames: existingNames)
            let sortIdx = SnippetStore.nextSnippetSortIndex(in: group, ungrouped: existingUngrouped)
            let newID = UUID()

            let (body, bodyRef) = try resolveImportSnippetBody(
                dto: dto, newID: newID, shouldSecure: dto.bodyRef != nil && !dto.body.isEmpty
            )

            let snippet = Snippet(
                id: newID, name: name, body: body,
                bodyRef: bodyRef,
                notes: dto.notes ?? "",
                appendsReturn: dto.appendsReturn ?? false,
                sortIndex: sortIdx, group: group
            )

            context.insert(snippet)
            if group == nil { ungroupedNames.insert(name) }
            count += 1
        }
        return count
    }
}
