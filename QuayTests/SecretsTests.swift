import Foundation
import Testing
@testable import Quay

@Suite("SecretReference")
struct SecretReferenceTests {

    @Test("keychain://service/account parses both fields")
    func keychainBasic() throws {
        let ref = try SecretReference("keychain://my-service/my-account")
        #expect(ref.scheme == .keychain)
        #expect(ref.keychainService == "my-service")
        #expect(ref.keychainAccount == "my-account")
    }

    @Test("keychain account may contain slashes")
    func keychainAccountWithSlash() throws {
        let ref = try SecretReference("keychain://quay/host/sudo_password")
        #expect(ref.keychainService == "quay")
        #expect(ref.keychainAccount == "host/sudo_password")
    }

    @Test("empty / malformed inputs throw the right errors")
    func parseErrors() {
        #expect(throws: SecretReference.ParseError.empty) {
            _ = try SecretReference("")
        }
        #expect(throws: SecretReference.ParseError.missingScheme) {
            _ = try SecretReference("keychain:my-service/account")
        }
        #expect(throws: SecretReference.ParseError.unknownScheme("vault")) {
            _ = try SecretReference("vault://x/y")
        }
        #expect(throws: SecretReference.ParseError.unknownScheme("op")) {
            _ = try SecretReference("op://Personal/x/password")
        }
        #expect(throws: SecretReference.ParseError.missingPath) {
            _ = try SecretReference("keychain://")
        }
    }
}

@Suite("AskpassServer + helper", .serialized)
struct AskpassIntegrationTests {

    /// Path to the bundled `quay-askpass` helper.
    /// Tests are hosted by Quay.app (TEST_HOST in project.yml), so the host
    /// binary directory contains the helper.
    private static func helperPath() throws -> String {
        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/quay-askpass")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw HelperError.notFound(helperURL.path)
        }
        return helperURL.path
    }

    enum HelperError: Error { case notFound(String) }

    @Test("helper reads bytes from the server socket and writes them to stdout")
    func helperRoundTrip() async throws {
        let secret = "hunter2-mysecret-\(UUID().uuidString)"
        let server = AskpassServer(resolve: {
            SensitiveBytes(Data(secret.utf8))
        })
        try server.start()
        defer { server.stop() }

        let helper = try Self.helperPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.environment = ["QUAY_ASKPASS_SOCKET": server.socketPath]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrStr = String(
            decoding: stderrPipe.fileHandleForReading.availableData,
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0,
                Comment(rawValue: "helper exited \(process.terminationStatus); stderr: \(stderrStr)"))

        let stdoutBytes = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutStr = String(decoding: stdoutBytes, as: UTF8.self)
        #expect(stdoutStr == secret,
                Comment(rawValue: "stdout=\(stdoutStr.debugDescription) " +
                                  "expected=\(secret.debugDescription) " +
                                  "stderr=\(stderrStr.debugDescription)"))
    }

    @Test("helper with no QUAY_ASKPASS_SOCKET set exits non-zero")
    func helperMissingEnv() async throws {
        let helper = try Self.helperPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.environment = [:]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }
}

