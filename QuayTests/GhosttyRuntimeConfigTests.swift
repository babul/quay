import Testing
import AppKit
import Foundation
import GhosttyKit
import SwiftUI
@testable import Quay

/// Exercises the shared `GhosttyRuntime` itself.
///
/// `GhosttyConfigTests` proves libghostty's config semantics against an
/// isolated harness, but the harness only *mirrors* `reloadConfig(soft:)` —
/// it would keep passing if the real one regressed. These tests drive the
/// real singleton and compare it against a config resolved independently
/// from the same sources, so the two cannot drift apart unnoticed.
///
/// Serialized because they mutate the shared runtime's color scheme, which is
/// process-global. Each test restores it.
@Suite("Ghostty runtime config", .serialized)
@MainActor
struct GhosttyRuntimeConfigTests {
    /// The runtime layers the user's own Ghostty config over Quay's bundled
    /// defaults, so the reference has to as well or the comparison is
    /// machine-dependent. A developer with a single `theme = X` makes these
    /// assertions trivially true rather than wrong.
    private func reference(for scheme: ghostty_color_scheme_e) throws -> String {
        let harness = try #require(GhosttyConfigHarness(contents: "", includeUserConfig: true))
        harness.setColorScheme(scheme)
        return harness.backgroundHex
    }

    private var runtimeBackground: String {
        GhosttyConfigReader.backgroundHex(GhosttyRuntime.shared.config)
    }

    /// These run inside the live Quay app, so they restore the appearance the
    /// app was actually running under rather than leaving it flipped.
    private func withRestoredColorScheme(_ body: () throws -> Void) rethrows {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        defer { GhosttyRuntime.shared.setColorScheme(isDark ? .dark : .light) }
        try body()
    }

    /// The v0.5.0 bug lived here: the runtime resolved its theme once and then
    /// pinned it, so `setColorScheme(.dark)` moved libghostty's conditional
    /// state while the runtime's own config stayed on the light half.
    @Test("Runtime resolves the same background as an independent config")
    func runtimeMatchesIndependentResolution() throws {
        try withRestoredColorScheme {
            let dark = try reference(for: GHOSTTY_COLOR_SCHEME_DARK)
            let light = try reference(for: GHOSTTY_COLOR_SCHEME_LIGHT)

            GhosttyRuntime.shared.setColorScheme(.dark)
            #expect(runtimeBackground == dark)

            GhosttyRuntime.shared.setColorScheme(.light)
            #expect(runtimeBackground == light)
        }
    }

    @Test("Repeated appearance switches keep tracking the scheme")
    func repeatedSwitchesKeepTracking() throws {
        try withRestoredColorScheme {
            let dark = try reference(for: GHOSTTY_COLOR_SCHEME_DARK)
            let light = try reference(for: GHOSTTY_COLOR_SCHEME_LIGHT)

            for iteration in 1...3 {
                GhosttyRuntime.shared.setColorScheme(.dark)
                #expect(runtimeBackground == dark, "dark lost on iteration \(iteration)")
                GhosttyRuntime.shared.setColorScheme(.light)
                #expect(runtimeBackground == light, "light lost on iteration \(iteration)")
            }
        }
    }

    /// A reload re-reads the config files; it must not also reset the
    /// appearance. Both kinds have to leave the resolved palette alone.
    @Test("Neither reload kind disturbs the active appearance")
    func reloadPreservesAppearance() throws {
        try withRestoredColorScheme {
            for scheme in [ColorScheme.dark, .light] {
                GhosttyRuntime.shared.setColorScheme(scheme)
                let before = runtimeBackground

                GhosttyRuntime.shared.reloadConfig(soft: true)
                #expect(runtimeBackground == before, "soft reload changed the \(scheme) palette")

                GhosttyRuntime.shared.reloadConfig(soft: false)
                #expect(runtimeBackground == before, "hard reload changed the \(scheme) palette")
            }
        }
    }

    /// Every hard reload builds a fresh `ghostty_config_t` and frees the
    /// previous one while libghostty is mid-call. If the ownership handoff in
    /// `updateAppConfig` is wrong, this is where it surfaces.
    @Test("Repeated reloads stay stable")
    func repeatedReloadsAreStable() throws {
        try withRestoredColorScheme {
            GhosttyRuntime.shared.setColorScheme(.dark)
            let expected = runtimeBackground

            for _ in 0..<10 {
                GhosttyRuntime.shared.reloadConfig(soft: false)
                GhosttyRuntime.shared.reloadConfig(soft: true)
            }
            // Not asserting zero diagnostics here: a hard reload runs
            // `ghostty_config_load_cli_args`, and under the test runner argv
            // carries Xcode's own flags (`-NSTreatUnknownArgumentsAsOpen`,
            // `-ApplePersistenceIgnoreState`), which libghostty reports as
            // invalid fields. That is the harness's argv, not Quay's config.
            #expect(runtimeBackground == expected)
        }
    }
}
