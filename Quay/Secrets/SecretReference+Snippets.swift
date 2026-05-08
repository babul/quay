import Foundation

extension SecretReference {
    static let snippetKeychainService = "com.quay.snippets"

    static func snippetURI(snippetID: UUID) -> String {
        "keychain://\(snippetKeychainService)/\(snippetID.uuidString)"
    }
}
