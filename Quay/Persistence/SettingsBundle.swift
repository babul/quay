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

private struct SettingsPayload: Codable {
    let folders: [FolderDTO]
    let connections: [ConnectionDTO]
}

struct ImportSummary {
    let foldersAdded: Int
    let connectionsAdded: Int
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

    enum BundleError: Error, Equatable {
        case malformedFile
        case unsupportedVersion(found: Int)
        case wrongPassword
        case missingPassword
        case cyclicFolderGraph
    }

    // MARK: Encode

    static func encode(modelContext: ModelContext, password: SensitiveBytes?) throws -> Data {
        let allFolders = try modelContext.fetch(FetchDescriptor<Folder>())
        let allConnections = try modelContext.fetch(FetchDescriptor<ConnectionProfile>())

        let folderDTOs = allFolders.map { f in
            FolderDTO(
                id: f.id,
                name: f.name,
                iconName: f.iconName,
                sortIndex: f.sortIndex,
                parentID: f.parent?.id
            )
        }
        let connectionDTOs = allConnections.map { c in
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
                loginScriptStepsJSON: c.loginScriptStepsJSON,
                sortIndex: c.sortIndex,
                parentFolderID: c.parent?.id
            )
        }

        let payload = SettingsPayload(folders: folderDTOs, connections: connectionDTOs)
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
        modelContext: ModelContext,
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

        let (foldersAdded, idToImported) = try insertFolders(settingsPayload.folders, into: modelContext)
        let connectionsAdded = try insertConnections(
            settingsPayload.connections,
            idToImported: idToImported,
            into: modelContext
        )
        try modelContext.save()
        return ImportSummary(foldersAdded: foldersAdded, connectionsAdded: connectionsAdded)
    }

    // MARK: - Private helpers

    private static func mapMalformed<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw BundleError.malformedFile }
    }

    private static func aadData(version: Int) -> Data {
        Data("\(magic)|v\(version)".utf8)
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
}
