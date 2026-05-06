import AppKit
import GhosttyKit

// MARK: - Keyboard + NSTextInputClient (IME)
//
// Keyboard handling lives here rather than in the main class file because
// NSTextInputClient and keyDown need to be co-designed — the IME input path
// flows through interpretKeyEvents → insertText → keyTextAccumulator.
//
// The design mirrors Ghostty's own SurfaceView_AppKit.swift (lines 1096–2054)
// but is simplified to the subset that matters for the CJK / dead-key / emoji
// use-cases. See that file for the reference comments explaining each step.

extension GhosttySurfaceView {

    // MARK: Key events

    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Signal to insertText/setMarkedText that we're inside a keyDown.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        // Snapshot the keyboard layout so we can detect IME input-source changes.
        let keyboardIdBefore: String? = markedTextBefore ? nil : currentKeyboardLayoutID()

        // Run through the input method system so CJK / dead-key composition works.
        interpretKeyEvents([event])

        // If the input method switched layouts, it handled the event.
        if !markedTextBefore && keyboardIdBefore != currentKeyboardLayoutID() {
            return
        }

        // Push preedit state to libghostty.
        syncPreedit(clearIfNeeded: markedTextBefore)

        let composing = markedText.length > 0 || markedTextBefore

        let accumulated = keyTextAccumulator ?? []

        if markedTextBefore && !accumulated.isEmpty {
            // Preedit was committed by this keypress. Send each piece of committed
            // text, then decide if the triggering key itself should be replayed.
            for text in accumulated {
                guard !shouldSuppressComposingControlInput(text, composing: composing) else { continue }
                sendKeyText(action, event: event, text: text, composing: false)
            }
            // Re-send the key itself only for keys that aren't pure commit triggers
            // (e.g. Space after Korean composition should commit and also insert a space).
            if shouldReplayKeyAfterPreeditCommit(event) {
                sendKeyText(action, event: event, text: event.ghosttyCharacters, composing: false)
            }
        } else if !accumulated.isEmpty {
            // Normal IME commit (e.g. typing 'n' produces "n" via Japanese IME).
            for text in accumulated {
                guard !shouldSuppressComposingControlInput(text, composing: composing) else { continue }
                sendKeyText(action, event: event, text: text, composing: composing)
            }
        } else {
            // No accumulator — plain key event.
            if shouldSuppressComposingControlInput(event.characters, composing: composing) { return }
            sendKeyText(action, event: event, text: event.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key_ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key_ev)
    }

    override func flagsChanged(with event: NSEvent) {
        // Don't forward modifier changes while composing.
        if hasMarkedText() { return }
        guard let surface else { return }
        let action: ghostty_input_action_e = ghosttyMods(event.modifierFlags).rawValue != 0
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        let key_ev = event.ghosttyKeyEvent(action)
        _ = ghostty_surface_key(surface, key_ev)
    }

    override func doCommand(by selector: Selector) {
        // Prevent NSBeep for unimplemented commands.
    }

    // MARK: Private helpers

    private func sendKeyText(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String?,
        composing: Bool
    ) {
        guard let surface else { return }
        var key_ev = event.ghosttyKeyEvent(action)
        key_ev.composing = composing

        if let text, text.count > 0,
           let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                key_ev.text = ptr
                _ = ghostty_surface_key(surface, key_ev)
            }
        } else {
            _ = ghostty_surface_key(surface, key_ev)
        }
    }

    private func shouldReplayKeyAfterPreeditCommit(_ event: NSEvent) -> Bool {
        // Space commits Korean composition AND should itself be typed; most other
        // printable characters that commit preedit should also be typed.
        guard let chars = event.characters, !chars.isEmpty else { return false }
        guard let scalar = chars.unicodeScalars.first else { return false }
        return scalar.value >= 0x20
    }

    private func shouldSuppressComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex
        else { return false }
        return scalar.value < 0x20
    }
}

// MARK: - NSTextInputClient

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
        // If called outside a keyDown (e.g. mid-composition layout switch),
        // push preedit immediately.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attrs[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: String(cString: text.text), attributes: attrs)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        let cellSize = bridge?.state.cellSize ?? CGSize(width: 8, height: 16)
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // For QuickLook (range != selectedRange), return top-left of selection.
        if range.length > 0 && range != selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }

        // Ghostty: top-left origin → AppKit: bottom-left origin.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String:            chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        // Called outside keyDown — send directly.
        guard let surface, !chars.isEmpty else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: Preedit

    fileprivate func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
