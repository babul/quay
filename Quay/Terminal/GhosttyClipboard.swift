import AppKit
import GhosttyKit

/// One representation of clipboard contents, copied out of libghostty's
/// borrowed memory so it can outlive the callback that delivered it.
struct ClipboardContent: Equatable, Sendable {
    static let plainTextMIME = "text/plain"

    let mime: String
    let data: Data

    var plainText: String? {
        mime == Self.plainTextMIME ? String(decoding: data, as: UTF8.self) : nil
    }

    /// The data is `len` bytes and not necessarily null-terminated.
    static func copies(
        of contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> [ClipboardContent] {
        guard let contents else { return [] }
        return (0..<count).compactMap { index in
            let item = contents[index]
            guard let mime = item.mime else { return nil }
            let data = item.data.map { Data(bytes: $0, count: item.len) } ?? Data()
            return ClipboardContent(mime: String(cString: mime), data: data)
        }
    }

    static func mimes(of mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> [String] {
        guard let mimes else { return [] }
        return (0..<count).compactMap { index in mimes[index].map { String(cString: $0) } }
    }
}

/// A clipboard request libghostty wants the user to confirm, and the prompt
/// Quay shows for it.
struct ClipboardConfirmation: Equatable {
    enum Kind: Hashable {
        /// A paste the user started that libghostty considers unsafe, such
        /// as one carrying a newline into a shell without bracketed paste.
        case paste
        /// A program in the terminal reading the local clipboard.
        case read
        /// A program in the terminal replacing the local clipboard.
        case write
    }

    enum Decision: Equatable {
        case deny
        case allowOnce
        case allowForTab
    }

    static let previewLimit = 500

    let kind: Kind
    let tabTitle: String
    /// Supplied by the requesting program, so it is a claim, not an identity.
    let programName: String?
    let text: String?

    init?(request: ghostty_clipboard_request_e, tabTitle: String, programName: String?, text: String?) {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            kind = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
             GHOSTTY_CLIPBOARD_REQUEST_LIST:
            kind = .read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            kind = .write
        default:
            return nil
        }
        self.tabTitle = tabTitle
        self.programName = programName.flatMap { $0.isEmpty ? nil : $0 }
        self.text = text
    }

    var title: String {
        switch kind {
        case .paste: "Paste text that may run commands?"
        case .read: "Allow a program to read your clipboard?"
        case .write: "Allow a program to change your clipboard?"
        }
    }

    var message: String {
        switch kind {
        case .paste:
            return "The text contains a line break or control characters, so pasting it into "
                + "“\(tabTitle)” may run commands straight away."
                + previewParagraph
        case .read:
            // The clipboard itself is not shown: it may hold a password, and
            // the user already knows what they copied.
            return "\(requester) wants to read what you have copied. "
                + "The server will receive it, including any password on the clipboard."
        case .write:
            return "\(requester) wants to replace what you have copied." + previewParagraph
        }
    }

    /// In `NSAlert` order. The first button answers Return, so it is always
    /// the refusal: a program can raise this prompt while the user is typing.
    /// A paste offers no tab grant, because `clipboard-paste-protection =
    /// false` is the standing answer for that.
    var buttons: [(title: String, decision: Decision)] {
        switch kind {
        case .paste:
            [("Cancel", .deny), ("Paste", .allowOnce)]
        case .read, .write:
            [("Deny", .deny), ("Allow Once", .allowOnce), ("Allow for This Tab", .allowForTab)]
        }
    }

    private var requester: String {
        let program = programName.map {
            "A program calling itself “\(Self.displayable($0, limit: 80, keepingLineBreaks: false))”"
        } ?? "A program"
        return "\(program) in “\(tabTitle)”"
    }

    private var previewParagraph: String {
        guard let text, !text.isEmpty else { return "" }
        return "\n\n" + Self.displayable(text, limit: Self.previewLimit, keepingLineBreaks: true)
    }

    /// Remote-supplied text made safe to show: control and format characters
    /// (bidi overrides among them) could otherwise disguise what the prompt
    /// says, so each becomes U+FFFD.
    static func displayable(_ text: String, limit: Int, keepingLineBreaks: Bool) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            if keepingLineBreaks, scalar == "\n" || scalar == "\t" { return scalar }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return "\u{FFFD}"
            default: return scalar
            }
        }
        let visible = String(String.UnicodeScalarView(scalars))
        return visible.count > limit ? String(visible.prefix(limit)) + "…" : visible
    }
}

extension ClipboardConfirmation {
    @MainActor
    /// The completion also receives the alert, so its owner can forget it.
    @discardableResult
    func present(on window: NSWindow, completion: @escaping @MainActor (Decision, NSAlert) -> Void) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let decisions = buttons.map { button in
            alert.addButton(withTitle: button.title)
            return button.decision
        }
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            MainActor.assumeIsolated {
                completion(decisions.indices.contains(index) ? decisions[index] : .deny, alert)
            }
        }
        return alert
    }
}
