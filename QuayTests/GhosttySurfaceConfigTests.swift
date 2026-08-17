import Testing
import Foundation
import GhosttyKit
@testable import Quay

/// `withCConfig` stages Swift values as raw C pointers for
/// `ghostty_surface_new`. Everything here reads those pointers back *inside*
/// the closure, which is the only window where the contract says they are
/// valid. A mistake in this layer is silent: a mangled working directory or a
/// dropped environment variable reaches `ssh` and the session just misbehaves.
@Suite("Ghostty surface config marshalling")
struct GhosttySurfaceConfigTests {
    /// `withCConfig` only stores these; it never dereferences them. Computed
    /// rather than stored so they stay off the shared-mutable-state radar.
    private static var nsView: UnsafeMutableRawPointer { .init(bitPattern: 0x1000)! }
    private static var userdata: UnsafeMutableRawPointer { .init(bitPattern: 0x2000)! }

    private func withCConfig<T>(
        _ config: GhosttySurfaceConfig,
        _ body: (inout ghostty_surface_config_s) -> T
    ) -> T {
        config.withCConfig(nsView: Self.nsView, userdata: Self.userdata, body: body)
    }

    private func environment(
        _ cfg: ghostty_surface_config_s
    ) -> [String: String] {
        guard let vars = cfg.env_vars, cfg.env_var_count > 0 else { return [:] }
        return (0..<cfg.env_var_count).reduce(into: [:]) { result, index in
            let entry = vars[index]
            guard let key = entry.key, let value = entry.value else { return }
            result[String(cString: key)] = String(cString: value)
        }
    }

    // MARK: - Optional strings

    @Test("Nil string fields marshal to null pointers")
    func nilStringsBecomeNull() {
        let config = GhosttySurfaceConfig()
        withCConfig(config) { cfg in
            #expect(cfg.command == nil)
            #expect(cfg.working_directory == nil)
            #expect(cfg.initial_input == nil)
        }
    }

    @Test("String fields round-trip through their C pointers")
    func stringsRoundTrip() {
        var config = GhosttySurfaceConfig()
        config.command = "/usr/bin/ssh -p 2222 host"
        config.workingDirectory = "/Users/test/projects"
        config.initialInput = "echo hello\n"

        withCConfig(config) { cfg in
            #expect(cfg.command.map(String.init(cString:)) == "/usr/bin/ssh -p 2222 host")
            #expect(cfg.working_directory.map(String.init(cString:)) == "/Users/test/projects")
            #expect(cfg.initial_input.map(String.init(cString:)) == "echo hello\n")
        }
    }

    @Test("An empty string is distinct from nil")
    func emptyStringIsNotNil() {
        var config = GhosttySurfaceConfig()
        config.command = ""

        withCConfig(config) { cfg in
            let command = try? #require(cfg.command)
            #expect(command != nil)
            #expect(cfg.command.map(String.init(cString:)) == "")
        }
    }

    @Test("Non-ASCII paths and commands survive the C round-trip")
    func nonASCIIStringsRoundTrip() {
        var config = GhosttySurfaceConfig()
        config.workingDirectory = "/Users/test/Ünïcödé/日本語/📁"
        config.command = "echo 'héllo wörld — ✓'"

        withCConfig(config) { cfg in
            #expect(cfg.working_directory.map(String.init(cString:)) == "/Users/test/Ünïcödé/日本語/📁")
            #expect(cfg.command.map(String.init(cString:)) == "echo 'héllo wörld — ✓'")
        }
    }

    // MARK: - Environment

    @Test("An empty environment marshals to a null array with zero count")
    func emptyEnvironmentIsNull() {
        let config = GhosttySurfaceConfig()
        withCConfig(config) { cfg in
            #expect(cfg.env_vars == nil)
            #expect(cfg.env_var_count == 0)
        }
    }

    @Test("Every environment pair reaches the C array")
    func environmentRoundTrips() {
        var config = GhosttySurfaceConfig()
        config.environment = [
            "TERM": "xterm-ghostty",
            "SSH_ASKPASS": "/Applications/Quay.app/Contents/MacOS/QuayAskpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "QUAY_ASKPASS_SOCKET": "/tmp/quay-askpass-ABC123.sock",
        ]

        withCConfig(config) { cfg in
            #expect(cfg.env_var_count == 4)
            #expect(environment(cfg) == config.environment)
        }
    }

    @Test("A single environment pair marshals correctly")
    func singleEnvironmentPair() {
        var config = GhosttySurfaceConfig()
        config.environment = ["TERM": "xterm-ghostty"]

        withCConfig(config) { cfg in
            #expect(cfg.env_var_count == 1)
            #expect(environment(cfg) == ["TERM": "xterm-ghostty"])
        }
    }

    /// Askpass socket paths and remote directories can hold anything the
    /// filesystem allows, and the values are `strdup`ed through C.
    @Test("Environment values survive non-ASCII and whitespace")
    func environmentHandlesAwkwardValues() {
        var config = GhosttySurfaceConfig()
        config.environment = [
            "QUAY_LABEL": "prod – café ☕️",
            "QUAY_SPACED": "value with spaces",
            "QUAY_EQUALS": "a=b=c",
            "QUAY_EMPTY": "",
        ]

        withCConfig(config) { cfg in
            #expect(cfg.env_var_count == 4)
            #expect(environment(cfg) == config.environment)
        }
    }

    @Test("A large environment marshals every pair")
    func largeEnvironmentRoundTrips() {
        var config = GhosttySurfaceConfig()
        config.environment = Dictionary(
            uniqueKeysWithValues: (0..<64).map { ("QUAY_VAR_\($0)", "value-\($0)") }
        )

        withCConfig(config) { cfg in
            #expect(cfg.env_var_count == 64)
            #expect(environment(cfg) == config.environment)
        }
    }

    // MARK: - Scalars and fixed fields

    @Test("Scalar fields pass through unchanged")
    func scalarsPassThrough() {
        var config = GhosttySurfaceConfig()
        config.scaleFactor = 3.0
        config.fontSize = 15.5
        config.waitAfterCommand = false

        withCConfig(config) { cfg in
            #expect(cfg.scale_factor == 3.0)
            #expect(cfg.font_size == 15.5)
            #expect(cfg.wait_after_command == false)
        }
    }

    @Test("Defaults match the documented surface defaults")
    func defaultsAreStable() {
        let config = GhosttySurfaceConfig()
        withCConfig(config) { cfg in
            #expect(cfg.scale_factor == 2.0)
            #expect(cfg.font_size == 0, "0 means 'inherit the config font size'")
            #expect(cfg.wait_after_command == true)
        }
    }

    /// `userdata` round-trips through libghostty's runtime callbacks so they
    /// can recover the surface bridge; if it is not stored verbatim, every
    /// callback loses its way back.
    @Test("Platform, context, and userdata are set verbatim")
    func platformFieldsAreSet() {
        let config = GhosttySurfaceConfig()
        withCConfig(config) { cfg in
            #expect(cfg.platform_tag == GHOSTTY_PLATFORM_MACOS)
            #expect(cfg.context == GHOSTTY_SURFACE_CONTEXT_WINDOW)
            #expect(cfg.platform.macos.nsview == Self.nsView)
            #expect(cfg.userdata == Self.userdata)
        }
    }

    // MARK: - Closure contract

    @Test("The closure's return value is propagated to the caller")
    func returnValuePropagates() {
        var config = GhosttySurfaceConfig()
        config.command = "ssh host"

        let count = withCConfig(config) { cfg in
            cfg.command.map { strlen($0) } ?? 0
        }
        #expect(count == strlen("ssh host"))
    }

    /// All the pointers are alive simultaneously — the nested `withCString`
    /// scopes in `withCConfig` must not release an outer one early.
    @Test("Every staged pointer is valid at the same time")
    func allPointersValidTogether() {
        var config = GhosttySurfaceConfig()
        config.command = "ssh host"
        config.workingDirectory = "/tmp"
        config.initialInput = "ls\n"
        config.environment = ["A": "1", "B": "2"]

        withCConfig(config) { cfg in
            #expect(cfg.command.map(String.init(cString:)) == "ssh host")
            #expect(cfg.working_directory.map(String.init(cString:)) == "/tmp")
            #expect(cfg.initial_input.map(String.init(cString:)) == "ls\n")
            #expect(environment(cfg) == ["A": "1", "B": "2"])
        }
    }
}
