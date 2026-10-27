import AppKit
import Darwin
import Foundation
import GhosttyKit
import OSLog
import SwiftUI

@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    static let logger = Logger(subsystem: "io.github.babul.quay", category: "ghostty")

    private static var didInitializeGhostty = false

    let app: ghostty_app_t
    private(set) var config: ghostty_config_t

    private var colorSchemeOverride: ghostty_color_scheme_e?
    private var configInFlight: ghostty_config_t?
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

    /// Rebuilds the config and pushes it into libghostty.
    ///
    /// A soft reload reuses the config already in memory. libghostty asks for
    /// one when only its conditional state changed — an appearance switch is
    /// the common case — and re-reading the files there would be actively
    /// wrong. `ghostty_config_finalize` resolves `theme = light:…,dark:…` by
    /// splicing the chosen half's settings into the config's replay history,
    /// guarded on the scheme that was current at the time. Loading the files
    /// again on top of that finalized config appends a second, later copy of
    /// those settings, so the first-resolved half wins every subsequent replay
    /// and the pair can never flip. A hard reload therefore starts from a fresh
    /// config rather than layering onto the existing one.
    func reloadConfig(soft: Bool = false) {
        if !soft {
            guard let fresh = ghostty_config_new() else {
                Self.logger.error("ghostty_config_new returned nil; keeping current config")
                return
            }
            Self.loadUserConfig(into: fresh)
            ghostty_config_finalize(fresh)
            replaceConfig(with: fresh)
        }
        updateAppConfig()
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

    /// Hands the current config to libghostty, which resolves it against the
    /// app's conditional state and hands the result straight back through a
    /// `config_change` action — re-entrantly, before this call returns. That
    /// handler swaps `config` out, so the pointer passed here is kept alive
    /// until libghostty is finished with it.
    private func updateAppConfig() {
        let inFlight = config
        configInFlight = inFlight
        defer {
            configInFlight = nil
            if config != inFlight { ghostty_config_free(inFlight) }
        }
        ghostty_app_update_config(app, inFlight)
    }

    private func replaceConfig(with newConfig: ghostty_config_t) {
        if config != configInFlight { ghostty_config_free(config) }
        config = newConfig
    }

    private func installConfigClone(_ newConfig: ghostty_config_t) {
        replaceConfig(with: newConfig)
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

    static func userConfigURL() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let xdg = home.appending(path: ".config/ghostty/config")
        let appSupport = home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config")
        if fm.fileExists(atPath: xdg.path) { return xdg }
        if fm.fileExists(atPath: appSupport.path) { return appSupport }
        do {
            try fm.createDirectory(at: xdg.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.createFile(atPath: xdg.path, contents: Data()) {
                logger.error("Failed to create Ghostty config at \(xdg.path, privacy: .public)")
            }
        } catch {
            logger.error("Failed to create Ghostty config directory: \(error)")
        }
        return xdg
    }

    /// The version string of the linked libghostty, e.g. `"1.3.2-dev"`.
    /// Reported by `ghostty_info()`; falls back to `"unknown"` if unavailable.
    static var libghosttyVersion: String {
        let info = ghostty_info()
        guard let version = info.version, info.version_len > 0 else { return "unknown" }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(version).assumingMemoryBound(to: UInt8.self),
            count: Int(info.version_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Quay's bundled base config, shipped in the app bundle.
    static var bundledDefaultsURL: URL? {
        Bundle.main.url(forResource: "default-ghostty", withExtension: "conf")
    }

    /// Loads only Quay's bundled defaults — no user config, no CLI args.
    ///
    /// Split out from `loadUserConfig` so the bundled layer can be resolved on
    /// its own. Tests need that: anything that also reads the developer's
    /// `~/.config/ghostty/config` resolves differently on every machine.
    static func loadBundledDefaults(into config: ghostty_config_t) {
        guard let bundledDefaults = bundledDefaultsURL else { return }
        ghostty_config_load_file(config, bundledDefaults.path)
    }

    private static func loadUserConfig(into config: ghostty_config_t) {
        loadBundledDefaults(into: config)
        ghostty_config_load_default_files(config)
        ghostty_config_load_cli_args(config)
        ghostty_config_load_recursive_files(config)
    }
}

extension Notification.Name {
    static let ghosttyRuntimeConfigDidChange = Notification.Name("io.github.babul.quay.ghosttyRuntimeConfigDidChange")
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
                GhosttyRuntime.shared.reloadConfig(soft: action.action.reload_config.soft)
                return true
            }
            return bridge.handleAction(action)
        }
    }

    /// Quay serves plain text only: `text/plain` is the one representation
    /// it reads and the one type it lists.
    static let readClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafeMutableRawPointer?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Int,
        Bool
    ) -> ghostty_clipboard_read_result_e = { userdata, _, requestState, mimes, mimeCount, list in
        let userdataAddress = UInt(bitPattern: userdata)
        let stateAddress = UInt(bitPattern: requestState)
        let wantsText = ClipboardContent.mimes(of: mimes, count: mimeCount).contains(ClipboardContent.plainTextMIME)
        return MainActor.assumeIsolated {
            guard let view = bridge(forUserdataAddress: userdataAddress)?.view,
                  let surface = view.surface
            else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

            let state = UnsafeMutableRawPointer(bitPattern: stateAddress)
            // Belt and braces for every paste route into the pty —
            // middle-click included, which never touches injectPasteText.
            guard view.forwardsUserInput else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return GHOSTTY_CLIPBOARD_READ_STARTED
            }
            guard wantsText || list,
                  let string = NSPasteboard.general.string(forType: .string),
                  !string.isEmpty
            else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

            completeClipboardRequest(
                surface,
                contents: wantsText ? [ClipboardContent(mime: ClipboardContent.plainTextMIME, data: Data(string.utf8))] : [],
                available: list ? [ClipboardContent.plainTextMIME] : [],
                state: state
            )
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    /// Copies everything into C memory for the duration of the call: a
    /// confirmed completion can arrive long after the callback that offered
    /// the contents, whose memory was only borrowed.
    static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [ClipboardContent],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false,
        remember: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>?] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        func cString(_ string: String) -> UnsafePointer<CChar>? {
            let copy = strdup(string)
            strings.append(copy)
            return UnsafePointer(copy)
        }
        let cContents = contents.map { content in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(content.data.count, 1), alignment: 1)
            buffers.append(buffer)
            content.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: content.data.count)
            return ghostty_clipboard_content_s(
                mime: cString(content.mime),
                data: UnsafePointer(buffer.assumingMemoryBound(to: CChar.self)),
                len: content.data.count
            )
        }
        let cAvailable = available.map(cString)
        cContents.withUnsafeBufferPointer { contents in
            cAvailable.withUnsafeBufferPointer { available in
                var completion = ghostty_clipboard_complete_s(
                    contents: contents.baseAddress,
                    contents_len: contents.count,
                    available: available.baseAddress,
                    available_len: available.count,
                    confirmed: confirmed,
                    remember: remember
                )
                ghostty_surface_complete_clipboard_request(surface, &completion, state)
            }
        }
    }

    /// Reached only when libghostty's policy wants the user asked: an unsafe
    /// paste, or a program using the clipboard under `clipboard-read = ask`.
    /// Every request ends in a completion or a deny; one left unanswered
    /// leaves the program waiting on a reply, and its state is never freed.
    static let confirmReadClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<ghostty_clipboard_confirm_s>?,
        UnsafeMutableRawPointer?,
        ghostty_clipboard_request_e
    ) -> Void = { userdata, confirm, requestState, request in
        let userdataAddress = UInt(bitPattern: userdata)
        let stateAddress = UInt(bitPattern: requestState)
        let contents = ClipboardContent.copies(of: confirm?.pointee.contents, count: confirm?.pointee.contents_len ?? 0)
        let available = ClipboardContent.mimes(of: confirm?.pointee.available, count: confirm?.pointee.available_len ?? 0)
        let programName = confirm?.pointee.name.map { String(cString: $0) }
        let canRemember = confirm?.pointee.can_remember ?? false
        MainActor.assumeIsolated {
            guard let bridge = bridge(forUserdataAddress: userdataAddress),
                  let view = bridge.view,
                  let surface = view.surface
            else { return }
            let state = UnsafeMutableRawPointer(bitPattern: stateAddress)
            guard let confirmation = ClipboardConfirmation(
                request: request,
                tabTitle: bridge.tabTitle?() ?? "",
                programName: programName,
                text: contents.lazy.compactMap(\.plainText).first
            ), let window = view.window else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }

            // Held until answered, so a tab closed under the prompt denies it
            // (GhosttySurfaceView.deinit) and the late answer is ignored.
            bridge.pendingClipboardRequests.insert(stateAddress)
            decide(confirmation, for: bridge, on: window) { decision in
                guard bridge.pendingClipboardRequests.remove(stateAddress) != nil,
                      let view = bridge.view,
                      let surface = view.surface
                else { return }
                let state = UnsafeMutableRawPointer(bitPattern: stateAddress)
                // The session may have ended while the prompt was up; the
                // read callback's gate holds at the answer too.
                guard decision != .deny, view.forwardsUserInput else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                completeClipboardRequest(
                    surface,
                    contents: contents,
                    available: available,
                    state: state,
                    confirmed: true,
                    remember: decision == .allowForTab && canRemember
                )
            }
        }
    }

    /// Asks unless the tab already holds a grant for this kind of request,
    /// and records the grant when the user gives one.
    static func decide(
        _ confirmation: ClipboardConfirmation,
        for bridge: GhosttySurfaceBridge,
        on window: NSWindow,
        then act: @escaping @MainActor (ClipboardConfirmation.Decision) -> Void
    ) {
        guard !bridge.clipboardGrants.contains(confirmation.kind) else { return act(.allowOnce) }
        bridge.clipboardPrompts.append(confirmation.present(on: window) { decision, alert in
            bridge.clipboardPrompts.removeAll { $0 === alert }
            // A prompt still queued when its tab closed outlives the tab, and
            // must not act for it.
            guard bridge.view?.surface != nil else { return }
            if decision == .allowForTab { bridge.clipboardGrants.insert(confirmation.kind) }
            act(decision)
        })
    }

    /// `confirm` is libghostty asking for an OSC 52 write under
    /// `clipboard-write = ask`; that write never reaches
    /// `confirm_read_clipboard_cb`, so it is asked here.
    static let writeClipboardCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        ghostty_clipboard_e,
        UnsafePointer<ghostty_clipboard_content_s>?,
        Int,
        Bool
    ) -> Void = { userdata, _, content, count, confirm in
        let userdataAddress = UInt(bitPattern: userdata)
        let text = ClipboardContent.copies(of: content, count: count).lazy.compactMap(\.plainText).first
        guard let text, !text.isEmpty else { return }
        MainActor.assumeIsolated {
            // Resolved now: userdata is unretained, so turning it back into a
            // bridge after the hop could read a tab that has since closed.
            let bridge = bridge(forUserdataAddress: userdataAddress)
            DispatchQueue.main.async { [weak bridge] in
                MainActor.assumeIsolated {
                    guard confirm else { return setPasteboard(text) }
                    guard let bridge,
                          let window = bridge.view?.window,
                          let confirmation = ClipboardConfirmation(
                              request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                              tabTitle: bridge.tabTitle?() ?? "",
                              programName: nil,
                              text: text
                          )
                    else { return }
                    decide(confirmation, for: bridge, on: window) { decision in
                        if decision != .deny { setPasteboard(text) }
                    }
                }
            }
        }
    }

    static func setPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
            reloadConfig(soft: action.action.reload_config.soft)
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
}
