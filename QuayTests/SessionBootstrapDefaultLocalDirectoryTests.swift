import Testing
import Foundation
@testable import Quay

@Suite("SessionBootstrap.defaultLocalDirectory")
struct SessionBootstrapDefaultLocalDirectoryTests {

    // Restore UserDefaults after each test using withKnownIssue isn't needed —
    // we save/restore the key around each test manually.
    private let key = AppDefaultsKeys.sftpDefaultLocalDirectory
    private let defaults = UserDefaults.standard

    private func withStoredValue(_ value: String?, _ body: () -> Void) {
        let previous = defaults.string(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        body()
    }

    @Test("valid stored directory wins over Downloads")
    func validStoredDirectory() {
        let tmpDir = FileManager.default.temporaryDirectory.path
        withStoredValue(tmpDir) {
            #expect(SessionBootstrap.defaultLocalDirectory() == tmpDir)
        }
    }

    @Test("empty stored value falls back to ~/Downloads")
    func emptyStoredValue() {
        withStoredValue("") {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path
            #expect(SessionBootstrap.defaultLocalDirectory() == downloads)
        }
    }

    @Test("whitespace-only stored value treated as empty")
    func whitespaceStoredValue() {
        withStoredValue("   \t  ") {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path
            #expect(SessionBootstrap.defaultLocalDirectory() == downloads)
        }
    }

    @Test("non-existent stored path falls back to ~/Downloads")
    func nonExistentStoredPath() {
        withStoredValue("/nonexistent/path/that/will/never/exist") {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path
            #expect(SessionBootstrap.defaultLocalDirectory() == downloads)
        }
    }

    @Test("no stored value at all falls back to ~/Downloads")
    func noStoredValue() {
        withStoredValue(nil) {
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path
            #expect(SessionBootstrap.defaultLocalDirectory() == downloads)
        }
    }
}
