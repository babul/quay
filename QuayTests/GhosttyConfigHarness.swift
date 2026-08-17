import Foundation
import GhosttyKit
@testable import Quay

/// A libghostty app + config pair, isolated from `GhosttyRuntime.shared`.
///
/// Conditional (`light:…,dark:…`) config keys can only be re-resolved through
/// an app — `ghostty_app_set_color_scheme` moves the app's conditional state
/// and `ghostty_app_update_config` applies it — so exercising theme switching
/// requires one. Using the shared runtime instead would drag in the
/// developer's own `~/.config/ghostty/config` and resolve differently on every
/// machine, so this builds its own app over a caller-supplied config file.
///
/// Mirrors `GhosttyRuntime`'s reload rules deliberately: `reload(soft:)` here
/// is the same soft/hard split, so a change in libghostty's config semantics
/// fails these tests rather than silently changing app behavior.
@MainActor
final class GhosttyConfigHarness {
    private(set) var config: ghostty_config_t
    private let app: ghostty_app_t
    private let configPath: String

    private let includeUserConfig: Bool

    /// Loads Quay's bundled defaults, then `contents` on top — the same
    /// layering order as `GhosttyRuntime.loadUserConfig`.
    ///
    /// `includeUserConfig` adds the developer's own `~/.config/ghostty/config`
    /// to the stack, making the result machine-dependent. Only useful for
    /// comparing against `GhosttyRuntime.shared`, which reads it too.
    init?(contents: String, includeUserConfig: Bool = false) {
        let path = FileManager.default
            .temporaryDirectory
            .appending(path: "quay-test-\(UUID().uuidString).conf")
        guard (try? contents.write(to: path, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        self.configPath = path.path
        self.includeUserConfig = includeUserConfig

        guard let config = Self.buildConfig(at: configPath, includeUserConfig: includeUserConfig)
        else { return nil }
        var callbacks = ghostty_runtime_config_s()
        callbacks.action_cb = Self.actionCallback
        guard let app = ghostty_app_new(&callbacks, config) else {
            ghostty_config_free(config)
            return nil
        }
        self.config = config
        self.app = app
    }

    isolated deinit {
        ghostty_app_free(app)
        ghostty_config_free(config)
        try? FileManager.default.removeItem(atPath: configPath)
    }

    private static func buildConfig(
        at path: String,
        includeUserConfig: Bool
    ) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        GhosttyRuntime.loadBundledDefaults(into: config)
        if includeUserConfig { ghostty_config_load_default_files(config) }
        ghostty_config_load_file(config, path)
        ghostty_config_finalize(config)
        return config
    }

    /// libghostty hands the resolved config back through a `config_change`
    /// action delivered re-entrantly from inside `ghostty_app_update_config`.
    /// The C callback cannot capture, so the in-flight harness is parked here
    /// for the duration of that one call.
    private static var current: GhosttyConfigHarness?

    private static let actionCallback: @convention(c) (
        ghostty_app_t?,
        ghostty_target_s,
        ghostty_action_s
    ) -> Bool = { _, target, action in
        guard target.tag == GHOSTTY_TARGET_APP,
              action.tag == GHOSTTY_ACTION_CONFIG_CHANGE
        else { return false }
        MainActor.assumeIsolated {
            guard let harness = GhosttyConfigHarness.current,
                  let clone = ghostty_config_clone(action.action.config_change.config)
            else { return }
            harness.pendingConfig = clone
        }
        return false
    }

    private var pendingConfig: ghostty_config_t?

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        ghostty_app_set_color_scheme(app, scheme)
        // libghostty answers a scheme change with a soft reload request.
        reload(soft: true)
    }

    /// The soft/hard split from `GhosttyRuntime.reloadConfig(soft:)`.
    ///
    /// A hard reload builds a *fresh* `ghostty_config_t`; it never loads files
    /// into the existing one. See `reloadIntoFinalizedConfig` for what that
    /// costs.
    func reload(soft: Bool) {
        if !soft, let fresh = Self.buildConfig(at: configPath, includeUserConfig: includeUserConfig) {
            ghostty_config_free(config)
            config = fresh
        }
        Self.current = self
        defer { Self.current = nil }
        ghostty_app_update_config(app, config)
        if let resolved = pendingConfig {
            pendingConfig = nil
            ghostty_config_free(config)
            config = resolved
        }
    }

    /// The anti-pattern that broke light/dark switching: load the config files
    /// again into the already-finalized config instead of starting fresh.
    /// Only used to prove the constraint still holds.
    func reloadIntoFinalizedConfig() {
        GhosttyRuntime.loadBundledDefaults(into: config)
        if includeUserConfig { ghostty_config_load_default_files(config) }
        ghostty_config_load_file(config, configPath)
        ghostty_config_finalize(config)
        Self.current = self
        defer { Self.current = nil }
        ghostty_app_update_config(app, config)
        if let resolved = pendingConfig {
            pendingConfig = nil
            ghostty_config_free(config)
            config = resolved
        }
    }

    var backgroundHex: String { GhosttyConfigReader.backgroundHex(config) }
}

/// Typed reads over `ghostty_config_get`, which takes a `void*` out-parameter
/// whose real type depends on the key.
enum GhosttyConfigReader {
    static func string(_ config: ghostty_config_t, _ key: String) -> String? {
        var value: UnsafePointer<Int8>?
        guard get(config, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func double(_ config: ghostty_config_t, _ key: String) -> Double? {
        var value: Double = 0
        guard get(config, key, &value) else { return nil }
        return value
    }

    /// Ghostty stores some numbers as `f32`; reading those into a `Double`
    /// reinterprets the bits and yields garbage rather than failing.
    static func float(_ config: ghostty_config_t, _ key: String) -> Float? {
        var value: Float = 0
        guard get(config, key, &value) else { return nil }
        return value
    }

    static func uint32(_ config: ghostty_config_t, _ key: String) -> UInt32? {
        var value: UInt32 = 0
        guard get(config, key, &value) else { return nil }
        return value
    }

    static func bool(_ config: ghostty_config_t, _ key: String) -> Bool? {
        var value = false
        guard get(config, key, &value) else { return nil }
        return value
    }

    static func backgroundHex(_ config: ghostty_config_t) -> String {
        var color = ghostty_config_color_s()
        guard get(config, "background", &color) else { return "none" }
        return String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    static func diagnostics(_ config: ghostty_config_t) -> [String] {
        (0..<ghostty_config_diagnostics_count(config)).map { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            return diagnostic.message.map(String.init(cString:)) ?? "<no message>"
        }
    }

    private static func get(
        _ config: ghostty_config_t,
        _ key: String,
        _ out: UnsafeMutableRawPointer
    ) -> Bool {
        key.withCString { ptr in
            ghostty_config_get(config, out, ptr, UInt(strlen(ptr)))
        }
    }
}
