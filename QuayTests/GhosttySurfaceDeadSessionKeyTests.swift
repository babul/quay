import AppKit
import Testing
@testable import Quay

/// A dead session answers Space/Return (reconnect) and Escape (stop retrying).
/// The matcher has to be exact: a modifier combination that slips through here
/// would steal a keystroke from a live terminal, and one that is rejected
/// leaves the shortcut broken.
@Suite("Dead session key matching")
struct GhosttySurfaceDeadSessionKeyTests {
    private static let returnKey: UInt16 = 36
    private static let spaceKey: UInt16 = 49
    private static let keypadEnterKey: UInt16 = 76
    private static let escapeKey: UInt16 = 53

    @Test("Space, Return, and keypad Enter reconnect")
    func barePressesReconnect() {
        for code in [Self.returnKey, Self.spaceKey, Self.keypadEnterKey] {
            #expect(GhosttySurfaceView.deadSessionKey(keyCode: code, modifiers: []) == .reconnect)
        }
    }

    @Test("Escape stops an automatic retry cycle")
    func escapeCancels() {
        #expect(GhosttySurfaceView.deadSessionKey(keyCode: Self.escapeKey, modifiers: []) == .cancel)
    }

    @Test("Caps lock and the keypad flags do not block a match")
    func ignoredModifiers() {
        #expect(
            GhosttySurfaceView.deadSessionKey(keyCode: Self.spaceKey, modifiers: [.capsLock])
                == .reconnect
        )
        #expect(
            GhosttySurfaceView.deadSessionKey(
                keyCode: Self.keypadEnterKey,
                modifiers: [.function, .numericPad]
            ) == .reconnect
        )
    }

    @Test("Modified presses stay with the terminal")
    func modifiedPressesDoNotMatch() {
        for mods: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            #expect(GhosttySurfaceView.deadSessionKey(keyCode: Self.returnKey, modifiers: mods) == nil)
            #expect(GhosttySurfaceView.deadSessionKey(keyCode: Self.escapeKey, modifiers: mods) == nil)
        }
    }

    @Test("Other keys are left alone")
    func otherKeysDoNotMatch() {
        #expect(GhosttySurfaceView.deadSessionKey(keyCode: 0, modifiers: []) == nil)  // "a"
        #expect(GhosttySurfaceView.deadSessionKey(keyCode: 48, modifiers: []) == nil)  // tab
    }
}
