import Testing
import Foundation
@testable import Quay

/// Passes the stored value and a stand-in for `~/Downloads` directly: the
/// shared defaults hold the developer's own choice and are written by the
/// settings-bundle tests running alongside, and a fresh machine may have no
/// Downloads folder.
@Suite("SessionBootstrap.defaultLocalDirectory")
struct SessionBootstrapDefaultLocalDirectoryTests {
    /// Any directory that always exists and isn't the stored one in these tests.
    private let downloads = "/"

    private func resolved(stored: String?) -> String? {
        SessionBootstrap.defaultLocalDirectory(stored: stored, downloads: downloads)
    }

    @Test("valid stored directory wins over Downloads")
    func validStoredDirectory() {
        let tmpDir = FileManager.default.temporaryDirectory.path
        #expect(resolved(stored: tmpDir) == tmpDir)
    }

    @Test("empty stored value falls back to Downloads")
    func emptyStoredValue() {
        #expect(resolved(stored: "") == downloads)
    }

    @Test("whitespace-only stored value treated as empty")
    func whitespaceStoredValue() {
        #expect(resolved(stored: "   \t  ") == downloads)
    }

    @Test("non-existent stored path falls back to Downloads")
    func nonExistentStoredPath() {
        #expect(resolved(stored: "/nonexistent/path/that/will/never/exist") == downloads)
    }

    @Test("no stored value at all falls back to Downloads")
    func noStoredValue() {
        #expect(resolved(stored: nil) == downloads)
    }

    @Test("no stored value and no Downloads gives no directory")
    func noDownloads() {
        #expect(SessionBootstrap.defaultLocalDirectory(stored: nil, downloads: "/nonexistent-downloads") == nil)
    }
}
