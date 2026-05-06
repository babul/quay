import CommonCrypto
import CryptoKit
import Foundation

enum ExportCryptoError: Error, Equatable {
    case wrongPassword
    case malformed
    case kdfFailed
}

enum ExportCrypto {
    static let kdfIterations: UInt32 = 600_000
    static let saltLength = 16
    static let keyLength = 32
    private static let tagLength = 16

    static func encrypt(
        plaintext: Data,
        password: SensitiveBytes,
        salt: Data,
        nonce: AES.GCM.Nonce,
        aad: Data
    ) throws -> Data {
        let key = try deriveKey(password: password, salt: salt, iterations: kdfIterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    static func decrypt(
        ciphertext: Data,
        password: SensitiveBytes,
        salt: Data,
        nonce: AES.GCM.Nonce,
        aad: Data
    ) throws -> Data {
        guard ciphertext.count >= tagLength else { throw ExportCryptoError.malformed }
        let key = try deriveKey(password: password, salt: salt, iterations: kdfIterations)
        let body = ciphertext.dropLast(tagLength)
        let tag = ciphertext.suffix(tagLength)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
        } catch {
            throw ExportCryptoError.malformed
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch let error as CryptoKitError {
            if case .authenticationFailure = error { throw ExportCryptoError.wrongPassword }
            throw ExportCryptoError.malformed
        } catch {
            throw ExportCryptoError.malformed
        }
    }

    private static func deriveKey(
        password: SensitiveBytes,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: CCCryptorStatus = password.withUnsafeBytes { pwBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                    pwBuf.count,
                    saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltBuf.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw ExportCryptoError.kdfFailed }
        let key = SymmetricKey(data: derived)
        derived.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = memset_s(base, buf.count, 0, buf.count)
        }
        return key
    }
}
