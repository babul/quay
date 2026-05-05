import AppKit

// MARK: - Edit-menu / responder-chain actions
//
// `selectAll(_:)`, `cut`, `copy`, `paste` are NSResponder informal methods
// surfaced via @objc selectors — not Swift overrides. validateMenuItem
// comes from NSMenuItemValidation which we conform to below.

extension GhosttySurfaceView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let text = currentSelectionText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        // Terminals don't really cut — it's ambiguous (do you remove from
        // scrollback?). Fall back to copy so the menu item is non-destructive.
        copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        injectPasteText(text)
    }

    override func selectAll(_ sender: Any?) {
        _ = performBindingAction("select_all")
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return currentSelectionText() != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
