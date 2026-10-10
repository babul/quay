import Testing
import CoreGraphics
@testable import Quay

@Suite("Terminal scroll geometry")
struct TerminalScrollGeometryTests {
    /// 100 rows of scrollback over a 24-row screen, 10pt rows, with 5pt of
    /// padding around the grid.
    private func geometry(offset: UInt64) -> TerminalScrollGeometry {
        TerminalScrollGeometry(
            scrollbar: TerminalScrollbar(total: 124, offset: offset, len: 24),
            cellHeight: 10,
            contentHeight: 245
        )
    }

    @Test("Document covers all of scrollback plus the grid's padding")
    func documentHeight() {
        #expect(geometry(offset: 0).documentHeight == 1245)
    }

    @Test("At the bottom of scrollback the clip view sits at the document origin")
    func bottomOrigin() {
        #expect(geometry(offset: 100).clipOriginY == 0)
    }

    @Test("At the top of scrollback the clip view sits at the top of the document")
    func topOrigin() {
        let g = geometry(offset: 0)
        #expect(g.clipOriginY == 1000)
        #expect(g.clipOriginY + g.contentHeight == g.documentHeight)
    }

    @Test("A clip origin maps back to the row libghostty reported", arguments: [0, 1, 37, 100] as [UInt64])
    func roundTrip(offset: UInt64) {
        let g = geometry(offset: offset)
        #expect(g.row(atClipOriginY: g.clipOriginY) == Int(offset))
    }

    @Test("A report with more visible rows than total does not underflow")
    func shortScreen() {
        let g = TerminalScrollGeometry(
            scrollbar: TerminalScrollbar(total: 10, offset: 0, len: 24),
            cellHeight: 10,
            contentHeight: 245
        )
        #expect(g.clipOriginY == 0)
        #expect(g.row(atClipOriginY: 0) == 0)
    }
}

@Suite("Terminal scrollbar config")
@MainActor
struct TerminalScrollbarConfigTests {
    @Test("Scroller follows Ghostty's scrollbar setting", arguments: [
        ("", true),
        ("scrollbar = system", true),
        ("scrollbar = never", false),
    ])
    func honorsConfig(contents: String, shows: Bool) throws {
        let harness = try #require(GhosttyConfigHarness(contents: contents))
        #expect(TerminalScrollView.showsScrollbar(harness.config) == shows)
    }
}
