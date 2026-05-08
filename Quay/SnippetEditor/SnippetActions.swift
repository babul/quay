import AppKit
import Foundation

/// Shared paste/copy actions for snippets — used by the sidebar context menu,
/// snippet editor toolbar, and any future command palette.
@MainActor
enum SnippetActions {
    /// Pastes the snippet body into `tab`'s active terminal surface.
    ///
    /// `appendReturn` overrides the snippet's stored `appendsReturn` flag when non-nil,
    /// allowing context-menu "Paste & Run" to force a Return regardless of the stored setting.
    /// Secured snippets prompt Touch ID via `ReferenceResolver`.
    static func paste(
        _ snippet: Snippet,
        into tab: TerminalTabItem?,
        appendReturn: Bool? = nil
    ) async {
        guard let bridge = tab?.surfaceView?.bridge else { return }
        guard let text = await resolveBody(snippet) else { return }
        bridge.sendText(text)
        if appendReturn ?? snippet.appendsReturn {
            bridge.sendReturnKey()
        }
    }

    /// Copies the snippet body to the macOS clipboard.
    /// Secured snippets prompt Touch ID via `ReferenceResolver`.
    static func copy(_ snippet: Snippet) async {
        guard let text = await resolveBody(snippet) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Private

    private static func resolveBody(_ snippet: Snippet) async -> String? {
        if let uri = snippet.bodyRef {
            do {
                let bytes = try await ReferenceResolver().resolve(uri)
                return bytes.unsafeUTF8String()
            } catch {
                return nil
            }
        }
        return snippet.body.isEmpty ? nil : snippet.body
    }
}
