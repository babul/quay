import AppKit
import Carbon
import GhosttyKit

extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        GhosttyKeyInput(event: self, action: action, translationMods: translationMods).make()
    }

    var ghosttyCharacters: String? {
        GhosttyEventText(event: self).terminalText
    }
}

func currentKeyboardLayoutID() -> String? {
    KeyboardLayoutIdentity.currentID()
}

private struct GhosttyKeyInput {
    let event: NSEvent
    let action: ghostty_input_action_e
    let translationMods: NSEvent.ModifierFlags?

    func make() -> ghostty_input_key_s {
        ghostty_input_key_s(
            action: action,
            mods: ghosttyMods(event.modifierFlags),
            consumed_mods: ghosttyMods(consumedTextModifiers),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: unshiftedCodepoint,
            composing: false
        )
    }

    private var consumedTextModifiers: NSEvent.ModifierFlags {
        let flags = translationMods ?? event.modifierFlags
        return flags.subtracting([.control, .command])
    }

    private var unshiftedCodepoint: UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let scalar = event.characters(byApplyingModifiers: [])?.firstUnicodeScalar
        else { return 0 }
        return scalar.value
    }
}

private struct GhosttyEventText {
    let event: NSEvent

    var terminalText: String? {
        guard let characters = event.characters else { return nil }
        guard let scalar = characters.singleUnicodeScalar else { return characters }

        if scalar.isAppKitFunctionKey {
            return nil
        }
        if scalar.isControlCharacter {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        return characters
    }
}

private enum KeyboardLayoutIdentity {
    static func currentID() -> String? {
        currentInputSourceID()
            ?? keyboardLayoutSourceID()
            ?? asciiCapableLayoutSourceID()
    }

    private static func currentInputSourceID() -> String? {
        id(from: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
    }

    private static func keyboardLayoutSourceID() -> String? {
        id(from: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    private static func asciiCapableLayoutSourceID() -> String? {
        id(from: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    private static func id(from source: TISInputSource?) -> String? {
        guard let source,
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
    }
}

private extension String {
    var firstUnicodeScalar: UnicodeScalar? {
        unicodeScalars.first
    }

    var singleUnicodeScalar: UnicodeScalar? {
        guard unicodeScalars.count == 1 else { return nil }
        return unicodeScalars.first
    }
}

private extension UnicodeScalar {
    var isControlCharacter: Bool {
        value < 0x20
    }

    var isAppKitFunctionKey: Bool {
        (0xF700...0xF8FF).contains(value)
    }
}
