import AppKit
import Darwin
import Foundation
import GhosttyKit
import OSLog
import SwiftUI

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
    private static var didBootstrap = false

    let app: ghostty_app_t
    private(set) var config: ghostty_config_t
    private var lastColorScheme: ghostty_color_scheme_e?

    /// Weak set of live surface bridges — used to fan out config and theme
    /// changes to every running surface without strong-reference cycles.
    private var surfaceRefs = NSHashTable<GhosttySurfaceBridge>.weakObjects()

    func registerSurface(_ bridge: GhosttySurfaceBridge) {
        surfaceRefs.add(bridge)
        if let scheme = lastColorScheme {
            applyColorSchemeToSurfaces(scheme, bridge: bridge)
        }
    }

    func unregisterSurface(_ bridge: GhosttySurfaceBridge) {
        surfaceRefs.remove(bridge)
    }

    /// Reload the shared config and push it to every live surface.
    func reloadConfig() {
        Self.loadConfig(config)
        ghostty_config_finalize(config)
        ghostty_app_update_config(app, config)
        for bridge in surfaceRefs.allObjects {
            guard let surface = bridge.view?.surface else { continue }
            ghostty_surface_update_config(surface, config)
            bridge.state.updateBackground(from: config)
            bridge.view?.applyResolvedBackground()
        }
        if let scheme = lastColorScheme {
            ghostty_app_set_color_scheme(app, scheme)
            applyColorSchemeToSurfaces(scheme)
        }
        NotificationCenter.default.post(
            name: .ghosttyRuntimeConfigDidChange,
            object: self
        )
    }

    func setColorScheme(_ colorScheme: ColorScheme) {
        let scheme = colorScheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        guard scheme != lastColorScheme else { return }
        lastColorScheme = scheme
        ghostty_app_set_color_scheme(app, scheme)
        applyColorSchemeToSurfaces(scheme)
    }

    private init() {
        Self.bootstrapIfNeeded()

        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new returned nil")
        }
        Self.loadConfig(config)
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

    isolated deinit {
        ghostty_app_free(app)
        ghostty_config_free(config)
    }

    func tick() {
        ghostty_app_tick(app)
    }

    private func applyColorSchemeToSurfaces(_ scheme: ghostty_color_scheme_e) {
        for bridge in surfaceRefs.allObjects {
            applyColorSchemeToSurfaces(scheme, bridge: bridge)
        }
    }

    private func applyColorSchemeToSurfaces(_ scheme: ghostty_color_scheme_e, bridge: GhosttySurfaceBridge) {
        guard let surface = bridge.view?.surface else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    private func replaceConfig(with newConfig: ghostty_config_t) {
        ghostty_config_free(config)
        config = newConfig
        for bridge in surfaceRefs.allObjects {
            bridge.state.updateBackground(from: newConfig)
            bridge.view?.applyResolvedBackground()
        }
    }

    private static func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        configureBundledResources()
        let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        precondition(rc == GHOSTTY_SUCCESS, "ghostty_init failed (\(rc))")
        didBootstrap = true
    }

    private static func configureBundledResources() {
        guard let resourcesURL = Bundle.main.resourceURL else { return }

        let terminfoURL = resourcesURL.appending(path: "terminfo/78/xterm-ghostty")
        let ghosttyResourcesURL = resourcesURL.appending(path: "ghostty")
        guard FileManager.default.fileExists(atPath: terminfoURL.path),
              FileManager.default.fileExists(atPath: ghosttyResourcesURL.path)
        else { return }

        let bundledThemesURL = ghosttyResourcesURL.appending(path: "themes")

        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResourcesURL.path, 1)
        if !FileManager.default.fileExists(atPath: bundledThemesURL.path) {
            logger.warning("Configured partial Ghostty resources dir with no bundled themes: \(ghosttyResourcesURL.path, privacy: .public)")
        }
    }

    private static func loadConfig(_ config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
        ghostty_config_load_cli_args(config)
        ghostty_config_load_recursive_files(config)
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by `GhosttyRuntime.reloadConfig()` after config + all surfaces are updated.
    static let ghosttyRuntimeConfigDidChange = Notification.Name("com.montopolis.quay.ghosttyRuntimeConfigDidChange")
}

extension GhosttyRuntime {

    // MARK: Runtime callbacks
    //
    // All are `nonisolated static @convention(c)`. Surface-targeted callbacks
    // receive the surface's userdata (a GhosttySurfaceBridge pointer) as their
    // first argument. We restore the Swift object with `takeUnretainedValue`
    // and hop to @MainActor via `MainActor.assumeIsolated` — AppKit guarantees
    // surface callbacks fire on the main thread.

    private static let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        // libghostty coalesces redundant ticks internally, so we can safely
        // enqueue one per wakeup without a client-side pending flag (which would
        // need its own lock to be race-free since this callback fires off-main).
        DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
    }

    private static let action: @convention(c) (
        ghostty_app_t?,
        ghostty_target_s,
        ghostty_action_s
    ) -> Bool = { _, target, action in
        if target.tag == GHOSTTY_TARGET_APP {
            return MainActor.assumeIsolated {
                switch action.tag {
                case GHOSTTY_ACTION_CONFIG_CHANGE:
                    let source = action.action.config_change.config
                    guard let clone = ghostty_config_clone(source) else { return false }
                    GhosttyRuntime.shared.replaceConfig(with: clone)
                    return false
                case GHOSTTY_ACTION_RELOAD_CONFIG:
                    GhosttyRuntime.shared.reloadConfig()
                    return true
                default:
                    return false
                }
            }
        }

        // Only surface-targeted actions can be routed to a bridge.
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surfacePtr = target.target.surface,
              let userdataPtr = ghostty_surface_userdata(surfacePtr)
        else { return false }

        return withBridge(userdata: userdataPtr, default: false) { bridge in
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                GhosttyRuntime.shared.reloadConfig()
                return true
            }
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
        let stateBits = UInt(bitPattern: state)
        return withBridge(userdata: userdata, default: false) { bridge in
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
        withBridge(userdata: userdata, default: ()) { bridge in
            bridge.onCloseRequest?()
        }
    }

    /// Restores a `GhosttySurfaceBridge` from a C callback's userdata pointer and
    /// runs `body` on the main actor. Returns `defaultValue` if the pointer is nil.
    @discardableResult
    private static func withBridge<T: Sendable>(
        userdata: UnsafeMutableRawPointer?,
        default defaultValue: T,
        body: @MainActor (GhosttySurfaceBridge) -> T
    ) -> T {
        guard let userdata else { return defaultValue }
        let bits = UInt(bitPattern: userdata)
        return MainActor.assumeIsolated {
            guard let ptr = UnsafeMutableRawPointer(bitPattern: bits) else { return defaultValue }
            let bridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(ptr).takeUnretainedValue()
            return body(bridge)
        }
    }
}
