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
        // Between sessions there is no session for a snippet to reach.
        guard let tab, let view = tab.surfaceView, view.forwardsUserInput else { return }
        guard let text = await resolveBody(snippet) else { return }
        // Re-checked after the await, and against the same surface: resolving a
        // secured snippet can sit on Touch ID for seconds, and the session may
        // have dropped meanwhile. `sendUserInput` re-checks the gate itself.
        guard tab.surfaceView === view,
              view.sendAutomatedInput(text, appendReturn: appendReturn ?? snippet.appendsReturn)
        else { return }
        // The send started in the sidebar or the snippet editor window; hand
        // the keyboard back to the session it went to — unless the user has
        // switched tabs during Touch ID, in which case that surface is hidden
        // and the host view would take focus straight back.
        guard TerminalTabManager.shared.selectedTab === tab else { return }
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
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
