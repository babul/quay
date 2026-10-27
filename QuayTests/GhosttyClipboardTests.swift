import Testing
import Foundation
import GhosttyKit
@testable import Quay

@Suite("Ghostty clipboard")
struct GhosttyClipboardTests {
    /// libghostty hands over `len` bytes that need not be null-terminated, so
    /// reading up to a terminator would take whatever follows in memory.
    @Test func contentCopiesOnlyItsLength() {
        let copies = "text/plain".withCString { mime in
            "hello world".withCString { data in
                var content = ghostty_clipboard_content_s(mime: mime, data: data, len: 5)
                return ClipboardContent.copies(of: &content, count: 1)
            }
        }
        #expect(copies.map(\.plainText) == ["hello"])
    }

    @Test func plainTextIsOnlyReadFromPlainText() {
        let html = ClipboardContent(mime: "text/html", data: Data("<b>x</b>".utf8))
        let plain = ClipboardContent(mime: "text/plain", data: Data("x".utf8))
        #expect(html.plainText == nil)
        #expect(plain.plainText == "x")
    }

    @Test(arguments: [
        (GHOSTTY_CLIPBOARD_REQUEST_PASTE, ClipboardConfirmation.Kind.paste),
        (GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, .read),
        (GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ, .read),
        (GHOSTTY_CLIPBOARD_REQUEST_LIST, .read),
        (GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, .write),
        (GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE, .write),
    ])
    func requestKinds(request: ghostty_clipboard_request_e, kind: ClipboardConfirmation.Kind) {
        let confirmation = ClipboardConfirmation(request: request, tabTitle: "web", programName: nil, text: nil)
        #expect(confirmation?.kind == kind)
    }

    /// A program can raise the prompt mid-typing, so Return must refuse.
    @Test(arguments: [GHOSTTY_CLIPBOARD_REQUEST_PASTE, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE])
    func returnRefuses(request: ghostty_clipboard_request_e) throws {
        let confirmation = try #require(ClipboardConfirmation(request: request, tabTitle: "web", programName: nil, text: nil))
        #expect(confirmation.buttons.first?.decision == .deny)
    }

    @Test func pasteOffersNoTabGrant() throws {
        let paste = try #require(ClipboardConfirmation(
            request: GHOSTTY_CLIPBOARD_REQUEST_PASTE, tabTitle: "web", programName: nil, text: "ls\n"
        ))
        let read = try #require(ClipboardConfirmation(
            request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, tabTitle: "web", programName: nil, text: nil
        ))
        #expect(!paste.buttons.contains { $0.decision == .allowForTab })
        #expect(read.buttons.contains { $0.decision == .allowForTab })
    }

    /// The prompt must not put the clipboard on screen: it may be a password.
    @Test func readPromptDoesNotShowTheClipboard() throws {
        let read = try #require(ClipboardConfirmation(
            request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, tabTitle: "web", programName: "nvim", text: "hunter2"
        ))
        #expect(!read.message.contains("hunter2"))
        #expect(read.message.contains("“nvim”"))
        #expect(read.message.contains("“web”"))
    }

    /// A remote program could otherwise reorder or hide what the prompt says.
    @Test func remoteTextIsShownWithoutControlOrBidiCharacters() throws {
        let read = try #require(ClipboardConfirmation(
            request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, tabTitle: "web",
            programName: "vim\u{202E}evil\nnext\u{1B}[2J", text: nil
        ))
        #expect(read.message.contains("“vim\u{FFFD}evil\u{FFFD}next\u{FFFD}[2J”"))
        #expect(ClipboardConfirmation.displayable("a\nb\tc\u{7}", limit: 10, keepingLineBreaks: true) == "a\nb\tc\u{FFFD}")
    }

    @Test func writePromptPreviewsTruncatedText() throws {
        let long = String(repeating: "a", count: ClipboardConfirmation.previewLimit + 10)
        let write = try #require(ClipboardConfirmation(
            request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, tabTitle: "web", programName: nil, text: long
        ))
        #expect(write.message.hasSuffix(String(repeating: "a", count: ClipboardConfirmation.previewLimit) + "…"))
    }
}
