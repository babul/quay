import AppKit
import Testing
@testable import Quay

/// A dead session swallows Space/Return to reconnect. The matcher has to be
/// exact: a modifier combination that slips through here would steal a keystroke
/// from a live terminal, and one that is rejected leaves the shortcut broken.
@Suite("Reconnect key matching")
struct GhosttySurfaceReconnectKeyTests {
    private static let returnKey: UInt16 = 36
    private static let spaceKey: UInt16 = 49
    private static let keypadEnterKey: UInt16 = 76

    @Test("Space, Return, and keypad Enter reconnect")
    func barePressesMatch() {
        for code in [Self.returnKey, Self.spaceKey, Self.keypadEnterKey] {
            #expect(GhosttySurfaceView.isReconnectKey(keyCode: code, modifiers: []))
        }
    }

    @Test("Caps lock and the keypad flags do not block a match")
    func ignoredModifiers() {
        #expect(GhosttySurfaceView.isReconnectKey(keyCode: Self.spaceKey, modifiers: [.capsLock]))
        #expect(
            GhosttySurfaceView.isReconnectKey(
                keyCode: Self.keypadEnterKey,
                modifiers: [.function, .numericPad]
            )
        )
    }

    @Test("Modified presses stay with the terminal")
    func modifiedPressesDoNotMatch() {
        for mods: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            #expect(!GhosttySurfaceView.isReconnectKey(keyCode: Self.returnKey, modifiers: mods))
        }
    }

    @Test("Other keys do not reconnect")
    func otherKeysDoNotMatch() {
        #expect(!GhosttySurfaceView.isReconnectKey(keyCode: 0, modifiers: []))  // "a"
        #expect(!GhosttySurfaceView.isReconnectKey(keyCode: 53, modifiers: []))  // escape
    }
}
