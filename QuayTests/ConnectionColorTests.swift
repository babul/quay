import Testing
@testable import Quay

@Suite("Connection colors")
struct ConnectionColorTests {
    @Test("known color tags resolve")
    func knownTagsResolve() {
        #expect(ConnectionColor.allTagIDs == ["red", "orange", "yellow", "green", "blue", "purple", "gray"])
        #expect(ConnectionColor.isKnown("blue"))
        #expect(ConnectionColor.label(for: "purple") == "Purple")
    }

    @Test("unknown color tags do not resolve")
    func unknownTagsDoNotResolve() {
        #expect(!ConnectionColor.isKnown(nil))
        #expect(!ConnectionColor.isKnown("teal"))
        #expect(ConnectionColor.color(for: "teal") == nil)
        #expect(ConnectionColor.label(for: "teal") == "teal")
    }

    @Test("connection icons resolve with default fallback")
    func connectionIconsResolve() {
        #expect(AppearanceIcon.allNames.contains("server.rack"))
        #expect(AppearanceIcon.isKnown("server.rack"))
        #expect(ConnectionIcon.systemName(for: nil) == "terminal.fill")
        #expect(ConnectionIcon.systemName(for: "server.rack") == "server.rack")
        #expect(ConnectionIcon.isKnown("server.rack"))
        #expect(!ConnectionIcon.isKnown("custom.symbol"))
    }

    @Test("folder icons use shared options with folder fallback")
    func folderIconsResolve() {
        #expect(FolderIcon.systemName(for: nil) == "folder")
        #expect(FolderIcon.systemName(for: "server.rack") == "server.rack")
        #expect(FolderIcon.isKnown("server.rack"))
        #expect(!FolderIcon.isKnown("custom.symbol"))
    }
}
