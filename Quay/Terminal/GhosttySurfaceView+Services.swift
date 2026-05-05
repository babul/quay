import AppKit

// MARK: - Services menu (used by PopClip + system services)

extension GhosttySurfaceView {
    /// Tell macOS we can produce a string for `sendType == .string` and
    /// (for paste-style services) consume one for `returnType == .string`.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && currentSelectionText() != nil)
        let canReturn = returnType == nil || returnType == .string
        if canSend && canReturn { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Write the current selection into a pasteboard for a Service to consume.
    @objc func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = currentSelectionText() else { return false }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    /// Receive a string from a Service that returns text. Treat it as a paste.
    @objc func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        injectPasteText(text)
        return true
    }
}
