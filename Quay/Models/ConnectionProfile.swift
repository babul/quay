import Foundation
import SwiftData

/// One saved SSH connection.
///
/// Stores zero plaintext secrets — only references to entries in the user's
/// vault (Keychain in v0.1, 1Password in v0.2). The `auth` computed property
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

    /// User-chosen color tag (e.g. "red", "amber"). Optional UI hint.
    var colorTag: String?

    /// User-chosen SF Symbol name for connection list display.
    var iconName: String?

    /// Free-form notes shown in the connection editor.
    var notes: String?

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
        colorTag: String? = nil,
        iconName: String? = nil,
        notes: String? = nil,
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
        self.colorTag = colorTag
        self.iconName = iconName
        self.notes = notes
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
            auth: auth
        )
    }
}
