import AppKit
import GhosttyKit
import Observation

enum GhosttyResolvedAppearance {
    static let fallbackBackgroundColor = NSColor.windowBackgroundColor
    static let fallbackBackgroundOpacity = 1.0

    static func backgroundColor(from config: ghostty_config_t?) -> NSColor {
        guard let config else { return fallbackBackgroundColor }

        var color = ghostty_config_color_s()
        let key = "background"
        let ok = key.withCString { ptr in
            ghostty_config_get(config, &color, ptr, UInt(strlen(ptr)))
        }
        guard ok else { return fallbackBackgroundColor }

        return NSColor(
            srgbRed: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }

    static func backgroundOpacity(from config: ghostty_config_t?) -> Double {
        guard let config else { return fallbackBackgroundOpacity }

        var opacity = fallbackBackgroundOpacity
        let key = "background-opacity"
        _ = key.withCString { ptr in
            ghostty_config_get(config, &opacity, ptr, UInt(strlen(ptr)))
        }
        return min(1.0, max(0.0, opacity))
    }

    static func backgroundColor(from change: ghostty_action_color_change_s) -> NSColor {
        NSColor(
            srgbRed: CGFloat(change.r) / 255.0,
            green: CGFloat(change.g) / 255.0,
            blue: CGFloat(change.b) / 255.0,
            alpha: 1.0
        )
    }

    static func color(_ color: NSColor, with opacity: Double) -> NSColor {
        color.withAlphaComponent(clampedAlpha(opacity))
    }

    static func clampedAlpha(_ opacity: Double) -> CGFloat {
        CGFloat(min(1.0, max(0.001, opacity)))
    }

    static func isOpaque(_ opacity: Double) -> Bool {
        clampedAlpha(opacity) >= 1.0
    }
}

/// Per-surface observable state read by SwiftUI overlays and the tab bar.
///
/// Mutated only by `GhosttySurfaceBridge.handleAction` on @MainActor.
/// SwiftUI reads are zero-cost because @Observable diffs at the property level.
@Observable
@MainActor
final class GhosttySurfaceState {
    /// Window/tab title reported by the running program (OSC 2 / GHOSTTY_ACTION_SET_TITLE).
    var title: String = ""

    /// Current working directory of the foreground process (OSC 7 / GHOSTTY_ACTION_PWD).
    var pwd: URL?

    /// Mouse cursor the surface wants the OS to display.
    var mouseCursor: NSCursor = .arrow

    /// Whether the surface is requesting a visible mouse cursor at all.
    var mouseVisible: Bool = true

    /// Whether libghostty has requested secure-input mode (password prompts).
    var secureInputActive: Bool = false

    /// Progress value [0.0, 1.0] from OSC 9;4 / GHOSTTY_ACTION_PROGRESS_REPORT.
    /// `nil` means no active progress.
    var progress: Double?

    /// Set `true` when GHOSTTY_ACTION_SHOW_CHILD_EXITED fires.
    /// The owning tab item uses this to transition its `Phase` to `.failed`.
    var childExited: Bool = false

    /// Cell size in points (needed for `firstRect(forCharacterRange:)` in the IME path).
    var cellSize: CGSize = CGSize(width: 8, height: 16)

    /// Resolved Ghostty terminal background used by host AppKit/SwiftUI chrome.
    var backgroundColor: NSColor = GhosttyResolvedAppearance.fallbackBackgroundColor

    /// Resolved Ghostty background opacity used by host AppKit/SwiftUI chrome.
    var backgroundOpacity: Double = GhosttyResolvedAppearance.fallbackBackgroundOpacity

    func updateBackground(from config: ghostty_config_t?) {
        backgroundColor = GhosttyResolvedAppearance.backgroundColor(from: config)
        backgroundOpacity = GhosttyResolvedAppearance.backgroundOpacity(from: config)
    }
}
