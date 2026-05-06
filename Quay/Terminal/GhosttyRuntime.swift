import AppKit
import Darwin
import Foundation
import GhosttyKit
import OSLog
import SwiftUI

@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    static let logger = Logger(subsystem: "com.montopolis.quay", category: "ghostty")

    private static var didInitializeGhostty = false

    let app: ghostty_app_t
    private(set) var config: ghostty_config_t

    private var colorSchemeOverride: ghostty_color_scheme_e?
    private var liveSurfaces = NSHashTable<GhosttySurfaceBridge>.weakObjects()

    private init() {
        Self.initializeGhosttyOnce()

        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new returned nil")
        }
        Self.loadUserConfig(into: config)
        ghostty_config_finalize(config)

        var callbacks = Self.runtimeCallbacks()
        guard let app = ghostty_app_new(&callbacks, config) else {
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

    func registerSurface(_ bridge: GhosttySurfaceBridge) {
        liveSurfaces.add(bridge)
        if let scheme = colorSchemeOverride, let surface = bridge.view?.surface {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    func unregisterSurface(_ bridge: GhosttySurfaceBridge) {
        liveSurfaces.remove(bridge)
    }

    func reloadConfig() {
        Self.loadUserConfig(into: config)
        ghostty_config_finalize(config)
        ghostty_app_update_config(app, config)
        refreshRegisteredSurfaces()
        reapplyColorSchemeOverride()
        postConfigDidChange()
    }

    func setColorScheme(_ colorScheme: ColorScheme) {
        let ghosttyScheme: ghostty_color_scheme_e = colorScheme == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        guard colorSchemeOverride != ghosttyScheme else { return }
        colorSchemeOverride = ghosttyScheme
        ghostty_app_set_color_scheme(app, ghosttyScheme)
        forEachSurface { surface, _ in
            ghostty_surface_set_color_scheme(surface, ghosttyScheme)
        }
    }

    private func refreshRegisteredSurfaces() {
        forEachSurface { surface, bridge in
            ghostty_surface_update_config(surface, config)
            bridge.state.updateBackground(from: config)
            bridge.view?.applyResolvedBackground()
        }
    }

    private func reapplyColorSchemeOverride() {
        guard let scheme = colorSchemeOverride else { return }
        ghostty_app_set_color_scheme(app, scheme)
        forEachSurface { surface, _ in
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    private func installConfigClone(_ newConfig: ghostty_config_t) {
        ghostty_config_free(config)
        config = newConfig
        forEachSurface { _, bridge in
            bridge.state.updateBackground(from: newConfig)
            bridge.view?.applyResolvedBackground()
        }
    }

    private func forEachSurface(_ body: (ghostty_surface_t, GhosttySurfaceBridge) -> Void) {
        for bridge in liveSurfaces.allObjects {
            guard let surface = bridge.view?.surface else { continue }
            body(surface, bridge)
        }
    }

    private func postConfigDidChange() {
        NotificationCenter.default.post(name: .ghosttyRuntimeConfigDidChange, object: self)
    }

    private static func initializeGhosttyOnce() {
        guard !didInitializeGhostty else { return }
        configureBundledResources()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        precondition(result == GHOSTTY_SUCCESS, "ghostty_init failed (\(result))")
        didInitializeGhostty = true
    }

    private static func configureBundledResources() {
        guard let resourceRoot = Bundle.main.resourceURL else { return }
        let ghosttyResourceRoot = resourceRoot.appending(path: "ghostty")
        let terminfo = resourceRoot.appending(path: "terminfo/78/xterm-ghostty")
        guard FileManager.default.fileExists(atPath: ghosttyResourceRoot.path),
              FileManager.default.fileExists(atPath: terminfo.path)
        else { return }

        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResourceRoot.path, 1)

        let themes = ghosttyResourceRoot.appending(path: "themes")
        if !FileManager.default.fileExists(atPath: themes.path) {
            logger.warning("Ghostty resource directory has no bundled themes: \(ghosttyResourceRoot.path, privacy: .public)")
        }
    }

    private static func loadUserConfig(into config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
        ghostty_config_load_cli_args(config)
        ghostty_config_load_recursive_files(config)
    }
}

extension Notification.Name {
    static let ghosttyRuntimeConfigDidChange = Notification.Name("com.montopolis.quay.ghosttyRuntimeConfigDidChange")
}

private extension GhosttyRuntime {
    static func runtimeCallbacks() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: wakeupCallback,
            action_cb: actionCallback,
            read_clipboard_cb: readClipboardCallback,
            confirm_read_clipboard_cb: confirmReadClipboardCallback,
            write_clipboard_cb: writeClipboardCallback,
            close_surface_cb: closeSurfaceCallback
        )
    }

    static let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        DispatchQueue.main.async {
            GhosttyRuntime.shared.tick()
        }
    }

    static let actionCallback: @convention(c) (
        ghostty_app_t?,
        ghostty_target_s,
        ghostty_action_s
    ) -> Bool = { _, target, action in
        MainActor.assumeIsolated {
            if target.tag == GHOSTTY_TARGET_APP {
                return GhosttyRuntime.shared.handleAppAction(action)
            }
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let bridge = bridge(for: surface)
            else { return false }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                GhosttyRuntime.shared.reloadConfig()
                return true
            }
            return bridge.handleAction(action)
        }
    }

    static let readClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafeMutableRawPointer?
    ) -> Bool = { userdata, _, requestState in
        let userdataAddress = UInt(bitPattern: userdata)
        let stateAddress = UInt(bitPattern: requestState)
        return MainActor.assumeIsolated {
            guard let bridge = bridge(forUserdataAddress: userdataAddress),
                  let surface = bridge.view?.surface,
                  let string = NSPasteboard.general.string(forType: .string),
                  !string.isEmpty
            else { return false }

            let state = UnsafeMutableRawPointer(bitPattern: stateAddress)
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }
    }

    static let confirmReadClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?,
        ghostty_clipboard_request_e
    ) -> Void = { _, _, _, _ in }

    static let writeClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafePointer<ghostty_clipboard_content_s>?,
        Int,
        Bool
    ) -> Void = { _, _, content, count, _ in
        guard let content, count > 0 else { return }
        let text = firstPlainText(in: content, count: count)
        guard let text, !text.isEmpty else { return }
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    static let closeSurfaceCallback: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { userdata, _ in
        let userdataAddress = UInt(bitPattern: userdata)
        MainActor.assumeIsolated {
            bridge(forUserdataAddress: userdataAddress)?.onCloseRequest?()
        }
    }

    func handleAppAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            guard let clone = ghostty_config_clone(action.action.config_change.config) else { return false }
            installConfigClone(clone)
            postConfigDidChange()
            return false
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
            return true
        default:
            return false
        }
    }

    static func bridge(for surface: ghostty_surface_t) -> GhosttySurfaceBridge? {
        guard let userdata = ghostty_surface_userdata(surface) else { return nil }
        return bridge(forUserdata: userdata)
    }

    static func bridge(forUserdata userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func bridge(forUserdataAddress address: UInt) -> GhosttySurfaceBridge? {
        guard let userdata = UnsafeMutableRawPointer(bitPattern: address) else { return nil }
        return bridge(forUserdata: userdata)
    }

    static func firstPlainText(
        in content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> String? {
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime, let data = item.data else { continue }
            guard String(cString: mime) == "text/plain" else { continue }
            return String(cString: data)
        }
        return nil
    }
}
