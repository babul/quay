import Foundation

/// A typed view over a secret-reference URI stored in `ConnectionProfile`.
///
/// Quay never stores plaintext — only references. One scheme is recognized:
///
///   keychain://service/account     macOS Keychain Services
struct SecretReference: Sendable, Equatable {
    enum Scheme: String, Sendable, Equatable {
        case keychain
    }

    let scheme: Scheme
    let raw: String
    /// Path components after the scheme. `keychain://a/b` → `["a", "b"]`.
    let path: [String]

    /// Convenience for `.keychain` refs.
    var keychainService: String? { scheme == .keychain ? path.first : nil }
    var keychainAccount: String? {
        guard scheme == .keychain, path.count >= 2 else { return nil }
        return path.dropFirst().joined(separator: "/")
    }
}

extension SecretReference {
    /// Service name used for all login-script Keychain entries.
    static let loginScriptKeychainService = "com.quay.scripts"

    /// Build the `keychain://` URI for a login-script step stored by Quay.
    static func loginScriptStepURI(stepID: UUID) -> String {
        "keychain://\(loginScriptKeychainService)/\(stepID.uuidString)"
    }

    /// Parse a URI and return the `(service, account)` pair if it's a valid
    /// `keychain://` reference. Used to bridge between the URI form stored in
    /// profiles and `KeychainStore`'s service/account API.
    static func keychainPair(forURI uri: String) -> (service: String, account: String)? {
        guard let ref = try? SecretReference(uri),
              let service = ref.keychainService,
              let account = ref.keychainAccount else { return nil }
        return (service, account)
    }
}

extension SecretReference {
    enum ParseError: Error, Equatable {
        case empty
        case missingScheme
        case unknownScheme(String)
        case missingPath
    }

    init(_ uri: String) throws {
        guard !uri.isEmpty else { throw ParseError.empty }
        guard let separator = uri.range(of: "://") else { throw ParseError.missingScheme }

        let schemeStr = String(uri[..<separator.lowerBound])
        guard let scheme = Scheme(rawValue: schemeStr) else {
            throw ParseError.unknownScheme(schemeStr)
        }

        let rest = String(uri[separator.upperBound...])
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ParseError.missingPath }

        self.scheme = scheme
        self.raw = uri
        self.path = parts
    }

}
