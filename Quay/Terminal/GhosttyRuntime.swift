import AppKit
import Foundation
import GhosttyKit
import OSLog

/// One-per-process wrapper around `ghostty_app_t` and the global config.
///
/// libghostty's runtime callbacks are `nonisolated static @convention(c)` —
/// they capture no Swift state. Each resolves a `GhosttySurfaceBridge` from
/// `ghostty_surface_userdata` and dispatches via `MainActor.assumeIsolated`
/// (safe because surface callbacks always arrive on the main thread in AppKit).
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

    // MARK: Runtime callbacks
    //
    // All are `nonisolated static @convention(c)`. Surface-targeted callbacks
    // receive the surface's userdata (a GhosttySurfaceBridge pointer) as their
    // first argument. We restore the Swift object with `takeUnretainedValue`
    // and hop to @MainActor via `MainActor.assumeIsolated` — AppKit guarantees
    // surface callbacks fire on the main thread.

    private static let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        // libghostty wants the embedder to schedule an `app_tick()` on the
        // main thread. Wired up in commit 6 (wakeup tick driver).
    }

    private static let action: @convention(c) (
        ghostty_app_t?,
        ghostty_target_s,
        ghostty_action_s
    ) -> Bool = { _, target, action in
        // Only surface-targeted actions can be routed to a bridge; app-level
        // actions (quit, new window) are handled in commit 8 via AppFeature.
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surfacePtr = target.target.surface,
              let userdataPtr = ghostty_surface_userdata(surfacePtr)
        else { return false }

        // Convert to Sendable UInt to cross nonisolated → @MainActor boundary.
        let bits = UInt(bitPattern: userdataPtr)
        return MainActor.assumeIsolated {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: bits) else { return false }
            let bridge = Unmanaged<GhosttySurfaceBridge>
                .fromOpaque(ptr)
                .takeUnretainedValue()
            return bridge.handleAction(action)
        }
    }

    /// Read the system pasteboard for paste / OSC-52 read.
    /// `userdata` is the surface's `GhosttySurfaceBridge`.
    private static let readClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafeMutableRawPointer?
    ) -> Bool = { userdata, _, state in
        guard let userdata else { return false }
        let bits = UInt(bitPattern: userdata)
        let stateBits = UInt(bitPattern: state)
        return MainActor.assumeIsolated {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: bits) else { return false }
            let bridge = Unmanaged<GhosttySurfaceBridge>
                .fromOpaque(ptr)
                .takeUnretainedValue()
            guard let surface = bridge.view?.surface else { return false }
            guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else {
                return false
            }
            let statePtr = UnsafeMutableRawPointer(bitPattern: stateBits)
            str.withCString { cPtr in
                ghostty_surface_complete_clipboard_request(surface, cPtr, statePtr, false)
            }
            return true
        }
    }

    /// OSC-52 paste confirmation. Confirmation UI deferred to v0.3.
    private static let confirmReadClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?,
        ghostty_clipboard_request_e
    ) -> Void = { _, _, _, _ in }

    /// Write to the system pasteboard for copy / OSC-52 write.
    private static let writeClipboard: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafePointer<ghostty_clipboard_content_s>?,
        Int,
        Bool
    ) -> Void = { _, _, content, len, _ in
        guard let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, let data = item.data else { continue }
            if String(cString: mime) == "text/plain" {
                let text = String(cString: data)
                guard !text.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                return
            }
        }
    }

    /// libghostty is asking us to close the surface (child exited or libghostty
    /// decided the session is done). Forward to the bridge's `onCloseRequest`.
    /// `userdata` is the surface's `GhosttySurfaceBridge`.
    private static let closeSurface: @convention(c) (
        UnsafeMutableRawPointer?,
        Bool
    ) -> Void = { userdata, _ in
        guard let userdata else { return }
        let bits = UInt(bitPattern: userdata)
        MainActor.assumeIsolated {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let bridge = Unmanaged<GhosttySurfaceBridge>
                .fromOpaque(ptr)
                .takeUnretainedValue()
            bridge.onCloseRequest?()
        }
    }
}
