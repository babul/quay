import Foundation

/// Dispatcher that turns a `SecretReference` into plaintext bytes.
struct ReferenceResolver: Sendable {
    enum ResolveError: Error, Equatable {
        case parseError(SecretReference.ParseError)
        case missingComponents
        case keychain(KeychainStore.KeychainError)
    }

    func resolve(_ uri: String) async throws -> SensitiveBytes {
        let ref: SecretReference
        do {
            ref = try SecretReference(uri)
        } catch let e as SecretReference.ParseError {
            throw ResolveError.parseError(e)
        }

        switch ref.scheme {
        case .keychain:
            guard let service = ref.keychainService,
                  let account = ref.keychainAccount else {
                throw ResolveError.missingComponents
            }
            do {
                return try KeychainStore.read(service: service, account: account)
            } catch let e as KeychainStore.KeychainError {
                throw ResolveError.keychain(e)
            }
        }
    }
}
