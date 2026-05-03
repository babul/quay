import AppKit
import Foundation
import GhosttyKit
import OSLog

/// One-per-process wrapper around `ghostty_app_t` and the global config.
///
/// The runtime callbacks libghostty requires are mostly no-ops in v0.1. As we
/// add features (clipboard sharing, app actions, OSC title updates) they get
/// implemented here, with `userdata` round-tripping through `Unmanaged`.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    static let logger = Logger(subsystem: "com.montopolis.quay", category: "ghostty")

    let app: ghostty_app_t
    let config: ghostty_config_t

    private init() {
        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new returned nil")
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyRuntime.wakeup,
            action_cb: GhosttyRuntime.action,
            read_clipboard_cb: GhosttyRuntime.readClipboard,
            confirm_read_clipboard_cb: GhosttyRuntime.confirmReadClipboard,
            write_clipboard_cb: GhosttyRuntime.writeClipboard,
            close_surface_cb: GhosttyRuntime.closeSurface
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            fatalError("ghostty_app_new returned nil")
        }

        self.config = config
        self.app = app
    }

    func tick() {
        ghostty_app_tick(app)
    }

    // MARK: Runtime callbacks (mostly stubs in v0.1)
    //
    // These run on libghostty's threads — they must be `@convention(c)` and
    // therefore cannot capture state. To act on `self`, route through
    // `userdata` (set in `ghostty_runtime_config_s.userdata`) via Unmanaged.

    private static let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        // libghostty wants the embedder to schedule an `app_tick()` on the
        // main thread. v0.1 lets the SwiftUI run loop drive ticks instead.
    }

    private static let action: @convention(c) (
        ghostty_app_t?,
        ghostty_target_s,
        ghostty_action_s
    ) -> Bool = { _, _, _ in
        // App-level actions (close window, open URL, new tab, etc.).
        // Wired up in v0.2.
        return false
    }

    private static let readClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafeMutableRawPointer?
    ) -> Bool = { _, _, _ in
        return false
    }

    private static let confirmReadClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?,
        ghostty_clipboard_request_e
    ) -> Void = { _, _, _, _ in }

    private static let writeClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafePointer<ghostty_clipboard_content_s>?,
        Int,
        Bool
    ) -> Void = { _, _, _, _, _ in }

    private static let closeSurface: @convention(c) (
        UnsafeMutableRawPointer?,
        Bool
    ) -> Void = { _, _ in }
}
