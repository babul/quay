import Foundation
import SwiftData

/// One Tabby-style login script step.
///
/// Steps are processed in `sortIndex` order. When `match` appears in the
/// visible terminal text, `send` is written to the PTY and the runner advances.
struct LoginScriptStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var match: String
    var send: String
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        match: String,
        send: String,
        sortIndex: Int
    ) {
        self.id = id
        self.match = match
        self.send = send
        self.sortIndex = sortIndex
    }
}

extension Array where Element == LoginScriptStep {
    var normalizedLoginScriptSteps: [LoginScriptStep] {
        self
            .map {
                LoginScriptStep(
                    id: $0.id,
                    match: $0.match.trimmingCharacters(in: .whitespacesAndNewlines),
                    send: $0.send.trimmingCharacters(in: .whitespacesAndNewlines),
                    sortIndex: $0.sortIndex
                )
            }
            .filter { !$0.match.isEmpty && !$0.send.isEmpty }
            .sorted { lhs, rhs in
                if lhs.sortIndex == rhs.sortIndex {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.sortIndex < rhs.sortIndex
            }
            .enumerated()
            .map { offset, step in
                LoginScriptStep(
                    id: step.id,
                    match: step.match,
                    send: step.send,
                    sortIndex: offset
                )
            }
    }
}

/// One saved SSH connection.
///
/// Stores zero plaintext secrets — only references to entries in the user's
/// Keychain. The `auth` computed property
/// reconstructs an `SSHAuth` from the stored fields for the command builder.
@Model
final class ConnectionProfile {
    @Attribute(.unique) var id: UUID

    /// Display name in the sidebar.
    var name: String

    /// Hostname or IP. Ignored when `authMethodRaw == .sshConfigAlias`.
    var hostname: String

    /// Port. `nil` = ssh's default (22, or whatever ~/.ssh/config dictates).
    var port: Int?

    /// Login username. `nil` = ssh's default (current OS user).
    var username: String?

    /// `AuthMethod.rawValue`. Stored as String so SwiftData can index it.
    var authMethodRaw: String

    /// Secret reference URI (e.g. `keychain://service/account`). Holds the
    /// password for `.password` auth, or the passphrase for
    /// `.privateKeyWithPassphrase`. `nil` for auth methods that need no secret.
    var secretRef: String?

    /// Filesystem path to a private key file. Only meaningful for the
    /// `.privateKey*` auth methods.
    var privateKeyPath: String?

    /// Host alias from `~/.ssh/config`. Only meaningful for the
    /// `.sshConfigAlias` auth method.
    var sshConfigAlias: String?

    /// Local directory used as the starting working directory for SFTP tabs.
    var localDirectory: String?

    /// Remote directory appended to the SFTP destination for interactive SFTP.
    var remoteDirectory: String?

    /// `RemoteTerminalType.rawValue` sent as TERM for this SSH session.
    var remoteTerminalTypeRaw: String?

    /// User-chosen color tag (e.g. "red", "amber"). Optional UI hint.
    var colorTag: String?

    /// User-chosen SF Symbol name for connection list display.
    var iconName: String?

    /// Free-form notes shown in the connection editor.
    var notes: String?

    /// JSON-encoded `[LoginScriptStep]`. Kept as optional text so old stores
    /// naturally read as "no login scripts" during lightweight migration.
    var loginScriptStepsJSON: String?

    /// Order within the parent folder (lower = higher in the list).
    var sortIndex: Int

    /// Containing folder. `nil` should not occur in normal operation.
    var parent: Folder?

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int? = nil,
        username: String? = nil,
        authMethod: AuthMethod = .sshAgent,
        secretRef: String? = nil,
        privateKeyPath: String? = nil,
        sshConfigAlias: String? = nil,
        localDirectory: String? = nil,
        remoteDirectory: String? = nil,
        remoteTerminalType: RemoteTerminalType = .defaultValue,
        colorTag: String? = nil,
        iconName: String? = nil,
        notes: String? = nil,
        loginScriptSteps: [LoginScriptStep] = [],
        sortIndex: Int = 0,
        parent: Folder? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.secretRef = secretRef
        self.privateKeyPath = privateKeyPath
        self.sshConfigAlias = sshConfigAlias
        self.localDirectory = localDirectory
        self.remoteDirectory = remoteDirectory
        self.remoteTerminalTypeRaw = remoteTerminalType.rawValue
        self.colorTag = colorTag
        self.iconName = iconName
        self.notes = notes
        self.loginScriptStepsJSON = Self.encodeLoginScriptSteps(loginScriptSteps)
        self.sortIndex = sortIndex
        self.parent = parent
    }

    enum AuthMethod: String, Codable, CaseIterable, Sendable {
        case sshAgent
        case privateKey
        case privateKeyWithPassphrase
        case password
        case sshConfigAlias
    }

    /// The stored auth as an enum. Returns `nil` if `authMethodRaw` is invalid.
    var authMethod: AuthMethod? {
        AuthMethod(rawValue: authMethodRaw)
    }

    var remoteTerminalType: RemoteTerminalType {
        get {
            guard let remoteTerminalTypeRaw,
                  let type = RemoteTerminalType(rawValue: remoteTerminalTypeRaw) else {
                return .defaultValue
            }
            return type
        }
        set {
            remoteTerminalTypeRaw = newValue.rawValue
        }
    }

    var loginScriptSteps: [LoginScriptStep] {
        get {
            guard let loginScriptStepsJSON,
                  let data = loginScriptStepsJSON.data(using: .utf8),
                  let decoded = try? Self.jsonDecoder.decode([LoginScriptStep].self, from: data) else {
                return []
            }
            return decoded.normalizedLoginScriptSteps
        }
        set {
            loginScriptStepsJSON = Self.encodeLoginScriptSteps(newValue)
        }
    }

    /// Reconstruct an `SSHAuth` from stored fields. Returns `nil` if the
    /// fields required by the chosen auth method are missing — in which case
    /// the connection is not yet ready to launch.
    var auth: SSHAuth? {
        guard let authMethod else { return nil }
        switch authMethod {
        case .sshAgent:
            return .sshAgent
        case .privateKey:
            guard let path = privateKeyPath else { return nil }
            return .privateKey(path: path)
        case .privateKeyWithPassphrase:
            guard let path = privateKeyPath, let ref = secretRef else { return nil }
            return .privateKeyWithPassphrase(path: path, passphraseRef: ref)
        case .password:
            guard let ref = secretRef else { return nil }
            return .password(passwordRef: ref)
        case .sshConfigAlias:
            guard let alias = sshConfigAlias else { return nil }
            return .sshConfigAlias(alias: alias)
        }
    }

    /// Convenience: build the `SSHTarget` the command builder consumes.
    var sshTarget: SSHTarget? {
        guard let auth else { return nil }
        return SSHTarget(
            hostname: hostname,
            port: port,
            username: username,
            auth: auth,
            remoteTerminalType: remoteTerminalType,
            localDirectory: localDirectory,
            remoteDirectory: remoteDirectory
        )
    }

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    private static func encodeLoginScriptSteps(_ steps: [LoginScriptStep]) -> String? {
        let normalized = steps.normalizedLoginScriptSteps
        guard !normalized.isEmpty,
              let data = try? jsonEncoder.encode(normalized) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
