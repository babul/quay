import Foundation
import GhosttyKit

/// Quay-side description of how a `ghostty_surface_t` should be created.
///
/// We hold Swift-native types here (String, [String: String]) and convert to
/// the C struct via `withCConfig` at the moment of `ghostty_surface_new`. The
/// C struct holds `const char*` pointers into Swift-owned storage that must
/// outlive the call, so all conversion happens inside one closure scope.
struct GhosttySurfaceConfig {
    /// Command to run, with arguments. Whitespace-separated. `nil` lets
    /// libghostty pick the user's shell.
    var command: String?
    /// Working directory for the spawned process. `nil` = inherit.
    var workingDirectory: String?
    /// Environment variables to set in the spawned process.
    var environment: [String: String] = [:]
    /// Initial input to pipe into the PTY (e.g. a paste). Usually `nil`.
    var initialInput: String?
    /// Whether the surface should hold open after the command exits.
    var waitAfterCommand: Bool = true
    /// Display content scale (HiDPI factor).
    var scaleFactor: Double = 2.0
    /// Optional font size override. `0` = use config default.
    var fontSize: Float = 0

    /// Build the C struct, run `body`, and free temporary allocations.
    ///
    /// The C struct stores raw pointers into the Strings in `self`, so callers
    /// must finish using `ghostty_surface_config_s` before this returns.
    func withCConfig<T>(
        nsView: UnsafeMutableRawPointer,
        body: (inout ghostty_surface_config_s) -> T
    ) -> T {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = nsView
        cfg.scale_factor = scaleFactor
        cfg.font_size = fontSize
        cfg.wait_after_command = waitAfterCommand
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Hold backing storage alive for the duration of `body`. C strings
        // borrowed via `withCString`/`withUnsafeBufferPointer` are only valid
        // inside their closure, so we nest accordingly below.

        return command.withCStringOrNull { commandPtr in
            workingDirectory.withCStringOrNull { wdPtr in
                initialInput.withCStringOrNull { inputPtr in
                    environment.withCEnvVars { envVars, count in
                        cfg.command = commandPtr
                        cfg.working_directory = wdPtr
                        cfg.initial_input = inputPtr
                        cfg.env_vars = envVars
                        cfg.env_var_count = count
                        return body(&cfg)
                    }
                }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    /// Like `String.withCString` but yields `nil` if `self` is `nil`.
    func withCStringOrNull<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value = self else { return body(nil) }
        return value.withCString { body($0) }
    }
}

private extension Dictionary where Key == String, Value == String {
    /// Stage the dictionary as a C array of `ghostty_env_var_s` whose key/value
    /// pointers remain valid for the duration of `body`. Backing memory is
    /// `strdup`-allocated and freed before returning.
    func withCEnvVars<T>(
        _ body: (UnsafeMutablePointer<ghostty_env_var_s>?, Int) -> T
    ) -> T {
        if isEmpty { return body(nil, 0) }

        var keyPtrs: [UnsafeMutablePointer<CChar>] = []
        var valPtrs: [UnsafeMutablePointer<CChar>] = []
        keyPtrs.reserveCapacity(count)
        valPtrs.reserveCapacity(count)

        for (key, value) in self {
            guard let k = strdup(key), let v = strdup(value) else {
                // strdup failed — clean up what we've allocated so far and bail.
                for p in keyPtrs { free(p) }
                for p in valPtrs { free(p) }
                return body(nil, 0)
            }
            keyPtrs.append(k)
            valPtrs.append(v)
        }
        defer {
            for p in keyPtrs { free(p) }
            for p in valPtrs { free(p) }
        }

        let cArray = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: count)
        defer { cArray.deallocate() }
        for i in 0..<count {
            cArray[i] = ghostty_env_var_s(key: keyPtrs[i], value: valPtrs[i])
        }
        return body(cArray, count)
    }
}
