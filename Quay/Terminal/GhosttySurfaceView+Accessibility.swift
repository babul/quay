import AppKit

// MARK: - Accessibility (so PopClip's accessibility-based selection reader works)

extension GhosttySurfaceView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilitySelectedText() -> String? { currentSelectionText() }

    override func accessibilityNumberOfCharacters() -> Int {
        currentSelectionText()?.count ?? 0
    }

    override func accessibilityValue() -> Any? {
        // Returning the entire scrollback would be expensive and most
        // selection-aware tools (PopClip) only need accessibilitySelectedText.
        // Hand them just the selection so "selected text" reads identically
        // to "value".
        currentSelectionText()
    }
}
