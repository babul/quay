import Foundation
import LocalAuthentication
import Security

/// Thin wrapper over Keychain Services for Quay's two operations:
///   1. Read a generic-password item by (service, account).
///   2. Enumerate accounts under a service (for the "Pick from Keychain" UI).
///
/// Quay never *writes* to Keychain. Users create entries via the OS
/// Keychain Access app, the `security` CLI, or 1Password's macOS-keychain
/// integration. Touch ID gating happens automatically when the matched
/// item's ACL requires it — the OS prompts; we just see plaintext or an
/// error.
enum KeychainStore {
    enum KeychainError: Error, Equatable {
        case itemNotFound
        case userCancelled
        case invalidData
        case osStatus(OSStatus)
    }

    /// Look up a generic-password item and return its data wrapped in a
    /// self-zeroing buffer.
    static func read(service: String, account: String) throws -> SensitiveBytes {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Ask the OS to display the Touch ID prompt (or the keychain
        // unlock dialog) inline if the item's ACL requires it.
        let authContext = LAContext()
        authContext.localizedReason = "Quay needs the secret for \(service)/\(account)"
        query[kSecUseAuthenticationContext as String] = authContext

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.invalidData }
            return SensitiveBytes(data)
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.userCancelled
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// List all accounts visible to us under `service`. Used by the
    /// "Pick from Keychain" UI (Step 7); not invoked at connect time.
    static func accounts(forService service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.osStatus(status)
        }
    }
}
