import CryptoKit
import Foundation
import Testing
@testable import Quay

@Suite("ExportCrypto")
struct ExportCryptoTests {

    private static func makePassword(_ string: String) -> SensitiveBytes {
        SensitiveBytes(Data(string.utf8))
    }

    @Test("PBKDF2 is deterministic: same password + salt → same key bytes")
    func pbkdf2Determinism() throws {
        let pw = Self.makePassword("hunter2")
        var saltBytes = [UInt8](repeating: 42, count: ExportCrypto.saltLength)
        let salt = Data(saltBytes)
        saltBytes[0] = 0 // ensure local mutation doesn't affect the Data copy

        let data1 = Data("plaintext".utf8)
        let data2 = Data("plaintext".utf8)
        let nonce1 = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let nonce2 = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let aad = Data("test|v1".utf8)

        let ct1 = try ExportCrypto.encrypt(plaintext: data1, password: pw, salt: salt, nonce: nonce1, aad: aad)
        let ct2 = try ExportCrypto.encrypt(plaintext: data2, password: pw, salt: salt, nonce: nonce2, aad: aad)
        #expect(ct1 == ct2)
    }

    @Test("Different salt → different ciphertext")
    func differentSaltProducesDifferentOutput() throws {
        let pw = Self.makePassword("hunter2")
        let salt1 = Data(repeating: 1, count: ExportCrypto.saltLength)
        let salt2 = Data(repeating: 2, count: ExportCrypto.saltLength)
        let plaintext = Data("secret".utf8)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let aad = Data("test|v1".utf8)

        let ct1 = try ExportCrypto.encrypt(plaintext: plaintext, password: pw, salt: salt1, nonce: nonce, aad: aad)
        let ct2 = try ExportCrypto.encrypt(plaintext: plaintext, password: pw, salt: salt2, nonce: nonce, aad: aad)
        #expect(ct1 != ct2)
    }

    @Test("AES-GCM round-trip with AAD")
    func roundTrip() throws {
        let pw = Self.makePassword("correct-horse-battery-staple")
        let salt = Data((0..<ExportCrypto.saltLength).map { UInt8($0) })
        let nonce = AES.GCM.Nonce()
        let aad = Data("quay.bundle|v1".utf8)
        let original = Data("Hello, Quay!".utf8)

        let ciphertext = try ExportCrypto.encrypt(plaintext: original, password: pw, salt: salt, nonce: nonce, aad: aad)
        let decrypted = try ExportCrypto.decrypt(ciphertext: ciphertext, password: pw, salt: salt, nonce: nonce, aad: aad)
        #expect(decrypted == original)
    }

    @Test("Wrong password → wrongPassword error")
    func wrongPasswordThrows() throws {
        let pw = Self.makePassword("correct")
        let wrongPw = Self.makePassword("incorrect")
        let salt = Data(repeating: 5, count: ExportCrypto.saltLength)
        let nonce = AES.GCM.Nonce()
        let aad = Data("quay.bundle|v1".utf8)
        let plaintext = Data("secret".utf8)

        let ciphertext = try ExportCrypto.encrypt(plaintext: plaintext, password: pw, salt: salt, nonce: nonce, aad: aad)
        #expect(throws: ExportCryptoError.wrongPassword) {
            try ExportCrypto.decrypt(ciphertext: ciphertext, password: wrongPw, salt: salt, nonce: nonce, aad: aad)
        }
    }

    @Test("Wrong AAD → wrongPassword error")
    func wrongAADThrows() throws {
        let pw = Self.makePassword("pw")
        let salt = Data(repeating: 3, count: ExportCrypto.saltLength)
        let nonce = AES.GCM.Nonce()
        let rightAAD = Data("quay.bundle|v1".utf8)
        let wrongAAD = Data("quay.bundle|v2".utf8)
        let plaintext = Data("aad-bound data".utf8)

        let ciphertext = try ExportCrypto.encrypt(plaintext: plaintext, password: pw, salt: salt, nonce: nonce, aad: rightAAD)
        #expect(throws: ExportCryptoError.wrongPassword) {
            try ExportCrypto.decrypt(ciphertext: ciphertext, password: pw, salt: salt, nonce: nonce, aad: wrongAAD)
        }
    }

    @Test("Truncated ciphertext (below tag size) → malformed error")
    func truncatedCiphertextThrows() throws {
        let pw = Self.makePassword("pw")
        let salt = Data(repeating: 1, count: ExportCrypto.saltLength)
        let nonce = AES.GCM.Nonce()
        let aad = Data("quay.bundle|v1".utf8)

        let ciphertext = Data(repeating: 0, count: 4) // too short for a 16-byte tag
        #expect(throws: ExportCryptoError.malformed) {
            try ExportCrypto.decrypt(ciphertext: ciphertext, password: pw, salt: salt, nonce: nonce, aad: aad)
        }
    }
}
