import Foundation
import LocalAuthentication
import Security

/// Thin wrapper over Keychain Services for Quay's credential operations:
///   1. Read a generic-password item by (service, account).
///   2. Write (upsert) a generic-password item — used only by the login-script
///      lock action; SSH credentials remain user-managed.
///   3. Delete a generic-password item.
///   4. Enumerate accounts under a service (for a "Pick from Keychain" UI).
///
/// Touch ID gating on read is automatic when the matched item's ACL requires
/// user presence — the OS prompts; we just see plaintext or an error.
enum KeychainStore {
    enum KeychainError: LocalizedError, Equatable {
        case itemNotFound
        case userCancelled
        case invalidData
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound: return "The Keychain item was not found."
            case .userCancelled: return "Authentication was cancelled."
            case .invalidData: return "The Keychain item contained unexpected data."
            case .osStatus(let status): return "Keychain error (OSStatus \(status))."
            }
        }
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

    /// Upsert a generic-password item. In properly signed builds the item is
    /// protected by user presence (Touch ID / device passcode). In unsigned /
    /// ad-hoc debug builds (where the biometric entitlement is unavailable) it
    /// falls back to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so tests
    /// and local development remain unblocked.
    ///
    /// SecItemUpdate cannot change an existing item's ACL, so we always
    /// delete-then-add to guarantee the ACL matches the current build's
    /// entitlements (important when re-locking after upgrading from a debug
    /// build to a signed release build).
    static func write(service: String, account: String, value: SensitiveBytes) throws {
        try delete(service: service, account: account)

        var addQuery = baseQuery(service: service, account: account)
        addQuery[kSecValueData as String] = value.unsafeData()

        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        )
        if let access {
            addQuery[kSecAttrAccessControl as String] = access
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        switch SecItemAdd(addQuery as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecMissingEntitlement:
            // Retry without user-presence ACL (unsigned/ad-hoc builds).
            addQuery.removeValue(forKey: kSecAttrAccessControl as String)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
        case let status:
            throw KeychainError.osStatus(status)
        }
    }

    /// Delete a generic-password item. Treats "not found" as success so callers
    /// can delete defensively without extra existence checks.
    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
