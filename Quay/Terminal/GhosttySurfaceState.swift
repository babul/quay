import AppKit
import Observation

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
}
