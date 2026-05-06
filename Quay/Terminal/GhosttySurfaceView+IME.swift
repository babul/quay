import AppKit
import CoreText
import GhosttyKit

extension GhosttySurfaceView {
    override func keyDown(with event: NSEvent) {
        let phase = KeyInputPhase(event: event, hadMarkedText: markedText.length > 0)
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        if phase.wasHandledByInputSourceChange(currentKeyboardLayoutID()) {
            return
        }

        syncPreedit(clearIfNeeded: phase.hadMarkedText)
        deliverKeyDown(event, phase: phase, committedText: keyTextAccumulator ?? [])
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_key(surface, event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE))
    }

    override func flagsChanged(with event: NSEvent) {
        guard markedText.length == 0, let surface else { return }
        let action: ghostty_input_action_e = ghosttyMods(event.modifierFlags).rawValue == 0
            ? GHOSTTY_ACTION_RELEASE
            : GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, event.ghosttyKeyEvent(action))
    }

    override func doCommand(by selector: Selector) {
        _ = selector
    }

    private func deliverKeyDown(
        _ event: NSEvent,
        phase: KeyInputPhase,
        committedText: [String]
    ) {
        let isComposing = markedText.length > 0

        if committedText.isEmpty {
            if isComposing && event.characters?.isSingleControlScalar == true { return }
            sendKey(event, action: phase.action, text: event.ghosttyCharacters, composing: isComposing)
            return
        }

        for text in committedText where shouldSendCommittedText(text, composing: isComposing) {
            sendKey(event, action: phase.action, text: text, composing: false)
        }

        if phase.hadMarkedText && shouldAlsoSendTriggeringKey(event, committedText: committedText) {
            sendKey(event, action: phase.action, text: event.ghosttyCharacters, composing: false)
        }
    }

    private func sendKey(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        text: String?,
        composing: Bool
    ) {
        guard let surface else { return }
        var keyEvent = event.ghosttyKeyEvent(action)
        keyEvent.composing = composing

        guard let text, text.isPrintableTerminalText else {
            _ = ghostty_surface_key(surface, keyEvent)
            return
        }

        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func shouldSendCommittedText(_ text: String, composing: Bool) -> Bool {
        !(composing && text.isSingleControlScalar)
    }

    private func shouldAlsoSendTriggeringKey(_ event: NSEvent, committedText: [String]) -> Bool {
        guard !committedText.isEmpty,
              let scalar = event.characters?.unicodeScalars.first
        else { return false }
        return scalar.value >= 0x20
    }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var selectedText = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selectedText) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &selectedText) }
        return NSRange(location: Int(selectedText.offset_start), length: Int(selectedText.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let replacement = Self.attributedMarkedText(from: string) else { return }
        _ = selectedRange
        _ = replacementRange
        markedText = replacement
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        _ = actualRange
        guard let surface, range.length > 0 else { return nil }
        var selectedText = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selectedText),
              let text = selectedText.text
        else { return nil }
        defer { ghostty_surface_free_text(surface, &selectedText) }

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            attributes[.font] = Unmanaged<CTFont>.fromOpaque(fontRaw).takeUnretainedValue()
        }
        return NSAttributedString(string: String(cString: text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        _ = actualRange
        guard let surface else {
            return window?.convertToScreen(convert(.zero, to: nil)) ?? .zero
        }

        var imeRect = ghosttyIMERect(surface: surface, range: range)
        if range.length == 0, imeRect.size.width > 0 {
            imeRect.origin.x += CGFloat(range.location) * terminalCellSize.width
            imeRect.size.width = 0
        }

        let appKitRect = NSRect(
            x: imeRect.origin.x,
            y: bounds.height - imeRect.origin.y,
            width: imeRect.width,
            height: max(imeRect.height, terminalCellSize.height)
        )
        let windowRect = convert(appKitRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        _ = replacementRange
        guard NSApp.currentEvent != nil,
              let text = Self.plainText(from: string)
        else { return }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.lengthOfBytes(using: .utf8)))
        }
    }

    fileprivate func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length == 0 {
            if clearIfNeeded {
                ghostty_surface_preedit(surface, nil, 0)
            }
            return
        }

        let text = markedText.string
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.lengthOfBytes(using: .utf8)))
        }
    }

    private var terminalCellSize: CGSize {
        bridge?.state.cellSize ?? CGSize(width: 8, height: 16)
    }

    private func ghosttyIMERect(surface: ghostty_surface_t, range: NSRange) -> NSRect {
        var x = 0.0
        var y = 0.0
        var width = Double(terminalCellSize.width)
        var height = Double(terminalCellSize.height)

        if range.length > 0, range != selectedRange() {
            var selectedText = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &selectedText) {
                x = selectedText.tl_px_x - 2
                y = selectedText.tl_px_y + 2
                ghostty_surface_free_text(surface, &selectedText)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func attributedMarkedText(from value: Any) -> NSMutableAttributedString? {
        switch value {
        case let attributed as NSAttributedString:
            return NSMutableAttributedString(attributedString: attributed)
        case let string as String:
            return NSMutableAttributedString(string: string)
        default:
            return nil
        }
    }

    private static func plainText(from value: Any) -> String? {
        switch value {
        case let attributed as NSAttributedString:
            return attributed.string
        case let string as String:
            return string
        default:
            return nil
        }
    }
}

private struct KeyInputPhase {
    let action: ghostty_input_action_e
    let hadMarkedText: Bool
    private let keyboardLayoutBefore: String?

    init(event: NSEvent, hadMarkedText: Bool) {
        self.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        self.hadMarkedText = hadMarkedText
        self.keyboardLayoutBefore = hadMarkedText ? nil : currentKeyboardLayoutID()
    }

    func wasHandledByInputSourceChange(_ keyboardLayoutAfter: String?) -> Bool {
        !hadMarkedText && keyboardLayoutBefore != keyboardLayoutAfter
    }
}

private extension String {
    var isPrintableTerminalText: Bool {
        guard let first = utf8.first else { return false }
        return first >= 0x20
    }

    var isSingleControlScalar: Bool {
        var iterator = unicodeScalars.makeIterator()
        guard let first = iterator.next(), iterator.next() == nil else { return false }
        return first.value < 0x20
    }
}
