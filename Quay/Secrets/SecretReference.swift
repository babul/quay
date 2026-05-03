import Foundation

/// A typed view over a secret-reference URI stored in `ConnectionProfile`.
///
/// Quay never stores plaintext — only references. Two schemes are recognized
/// (1Password lands in v0.2):
///
///   keychain://service/account     macOS Keychain Services
///   op://vault/item/field          1Password CLI (v0.2; throws in v0.1)
struct SecretReference: Sendable, Equatable {
    enum Scheme: String, Sendable, Equatable {
        case keychain
        case op
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
    enum ParseError: Error, Equatable {
        case empty
        case missingScheme
        case unknownScheme(String)
        case missingPath
        case unsupportedSchemeForVersion(Scheme)
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

    /// Parse a URI and reject schemes not yet implemented in this milestone.
    /// `keychain://` ✅ since v0.1; `op://` lands in v0.2.
    static func parseV01(_ uri: String) throws -> SecretReference {
        let ref = try SecretReference(uri)
        if ref.scheme == .op { throw ParseError.unsupportedSchemeForVersion(.op) }
        return ref
    }
}
