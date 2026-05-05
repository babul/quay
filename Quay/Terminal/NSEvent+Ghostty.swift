import AppKit
import Carbon
import GhosttyKit

extension NSEvent {
    /// Build a `ghostty_input_key_s` for this event.
    ///
    /// Does NOT set `text` or `composing` — those are set by the IME path
    /// in `GhosttySurfaceView+IME.swift`.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)
        key_ev.text = nil
        key_ev.composing = false

        key_ev.mods = ghosttyMods(modifierFlags)
        // macOS has no direct "consumed mods" API; approximate: ctrl and cmd
        // never contribute to text translation, so subtract them.
        key_ev.consumed_mods = ghosttyMods(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )

        // Unshifted codepoint: the codepoint with no modifiers applied.
        key_ev.unshifted_codepoint = 0
        if self.type == .keyDown || self.type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = scalar.value
            }
        }

        return key_ev
    }

    /// Text suitable for the `text` field of `ghostty_input_key_s`.
    ///
    /// Returns `nil` for control characters (Ghostty handles those internally)
    /// and for Private Use Area codepoints (function keys).
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                // Control char — return the uncontrolled version for encoding.
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                // Function key PUA — don't forward as text.
                return nil
            }
        }

        return characters
    }
}

/// Current keyboard input source ID (TIS), used to detect IME layout switches.
func currentKeyboardLayoutID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return (unsafeBitCast(idPtr, to: CFString.self) as String)
}
