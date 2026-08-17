import Testing
import Foundation
import GhosttyKit
@testable import Quay

/// Backgrounds of the two themes the bundled config names. `One Half Light`
/// is the load-bearing one: libghostty's no-theme fallback background happens
/// to equal `One Half Dark`, so only the light half distinguishes "the theme
/// loaded" from "the theme silently failed and fell back".
private enum ThemeBackground {
    static let oneHalfLight = "#FAFAFA"
    static let oneHalfDark = "#282C34"
}

@Suite("Bundled Ghostty config")
@MainActor
struct BundledGhosttyConfigTests {
    private func bundledConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        GhosttyRuntime.loadBundledDefaults(into: config)
        ghostty_config_finalize(config)
        return config
    }

    @Test("Bundled default-ghostty.conf is shipped in the app bundle")
    func bundledConfigIsShipped() throws {
        let url = try #require(GhosttyRuntime.bundledDefaultsURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// `theme = default` shipped in v0.4.x and was inert: no theme has that
    /// name, so libghostty logged two diagnostics per launch and fell back to
    /// its built-in palette. Nothing failed loudly. This is that alarm.
    @Test("Bundled config parses without diagnostics")
    func bundledConfigHasNoDiagnostics() throws {
        let config = try #require(bundledConfig())
        defer { ghostty_config_free(config) }

        let diagnostics = GhosttyConfigReader.diagnostics(config)
        #expect(diagnostics.isEmpty, "libghostty rejected part of the bundled config: \(diagnostics)")
    }

    /// Guards the test above against becoming vacuous — if `diagnostics` ever
    /// stopped reporting, the no-diagnostics assertion would pass forever.
    @Test("A bad key really does produce a diagnostic")
    func unknownKeyProducesDiagnostic() throws {
        let path = FileManager.default
            .temporaryDirectory
            .appending(path: "quay-test-bad-\(UUID().uuidString).conf")
        try "this-key-does-not-exist = 1\n".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, path.path)
        ghostty_config_finalize(config)

        #expect(!GhosttyConfigReader.diagnostics(config).isEmpty)
    }

    /// Only a subset of config keys is readable back through
    /// `ghostty_config_get` — a field's type needs a `cval`, which
    /// `window-padding-x`, `scrollback-limit-lines` and `theme` do not have.
    /// These are the ones that can be checked for effect directly;
    /// `everyBundledSettingIsAccepted` covers the rest.
    @Test("Readable bundled defaults take effect")
    func bundledDefaultsApply() throws {
        let config = try #require(bundledConfig())
        defer { ghostty_config_free(config) }

        #expect(GhosttyConfigReader.float(config, "font-size") == 13)
        #expect(GhosttyConfigReader.string(config, "cursor-style") == "block")
        #expect(GhosttyConfigReader.bool(config, "cursor-style-blink") == false)
    }

    /// Loads each setting from `default-ghostty.conf` on its own and requires
    /// it to parse clean. Derived from the file, so a setting added later is
    /// covered without touching this test.
    ///
    /// This is the guard for keys `ghostty_config_get` cannot read back: a
    /// libghostty bump that renames or drops one turns the bundled line into a
    /// diagnostic instead of silently meaning nothing, which is how
    /// `scrollback-limit` sat there as a 100 KB byte cap while the README
    /// documented 100,000 lines.
    @Test("Every setting in the bundled config is accepted on its own")
    func everyBundledSettingIsAccepted() throws {
        let url = try #require(GhosttyRuntime.bundledDefaultsURL)
        let settings = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        #expect(!settings.isEmpty, "bundled config has no settings to check")

        for setting in settings {
            let path = FileManager.default
                .temporaryDirectory
                .appending(path: "quay-test-line-\(UUID().uuidString).conf")
            try "\(setting)\n".write(to: path, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: path) }

            guard let config = ghostty_config_new() else {
                Issue.record("ghostty_config_new returned nil")
                return
            }
            defer { ghostty_config_free(config) }
            ghostty_config_load_file(config, path.path)
            ghostty_config_finalize(config)

            let diagnostics = GhosttyConfigReader.diagnostics(config)
            #expect(diagnostics.isEmpty, "libghostty rejected `\(setting)`: \(diagnostics)")
        }
    }

    /// Conditional themes resolve against libghostty's default conditional
    /// state, which is `.light`. Quay depends on this: the terminal is light
    /// until `setColorScheme` says otherwise.
    @Test("Bundled config resolves to its light half before any scheme is set")
    func bundledConfigResolvesLightByDefault() throws {
        let config = try #require(bundledConfig())
        defer { ghostty_config_free(config) }

        #expect(GhosttyConfigReader.backgroundHex(config) == ThemeBackground.oneHalfLight)
    }
}

@Suite("Ghostty appearance switching", .serialized)
@MainActor
struct GhosttyAppearanceSwitchingTests {
    private static let themePair = "theme = light:One Half Light,dark:One Half Dark"

    private func harness() throws -> GhosttyConfigHarness {
        try #require(GhosttyConfigHarness(contents: Self.themePair))
    }

    @Test("Setting the dark scheme resolves the dark half of the pair")
    func darkSchemeResolvesDarkTheme() throws {
        let harness = try harness()
        #expect(harness.backgroundHex == ThemeBackground.oneHalfLight)

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfDark)
    }

    /// The v0.5.0 bug. The pair resolved once at startup and never moved
    /// again, so a dark-mode user got a light terminal permanently. Every
    /// flip has to keep working, in both directions, indefinitely.
    @Test("Appearance switches keep flipping the theme in both directions")
    func repeatedSchemeChangesKeepFlipping() throws {
        let harness = try harness()

        for iteration in 1...3 {
            harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)
            #expect(
                harness.backgroundHex == ThemeBackground.oneHalfDark,
                "dark half lost on iteration \(iteration)"
            )
            harness.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT)
            #expect(
                harness.backgroundHex == ThemeBackground.oneHalfLight,
                "light half lost on iteration \(iteration)"
            )
        }
    }

    @Test("A hard reload preserves the active appearance")
    func hardReloadPreservesScheme() throws {
        let harness = try harness()
        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)

        harness.reload(soft: false)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfDark)

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT)
        harness.reload(soft: false)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfLight)
    }

    @Test("A soft reload preserves the active appearance")
    func softReloadPreservesScheme() throws {
        let harness = try harness()
        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)

        harness.reload(soft: true)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfDark)
    }

    /// The shipped config, not a synthetic pair. A single `theme = X` pins one
    /// palette in both appearances, so this is what stops Quay shipping an app
    /// that ignores the macOS appearance for anyone without their own Ghostty
    /// config.
    @Test("The bundled config's own theme follows the appearance")
    func bundledThemeFollowsAppearance() throws {
        let harness = try #require(GhosttyConfigHarness(contents: ""))
        #expect(harness.backgroundHex == ThemeBackground.oneHalfLight)

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfDark)

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfLight)
    }

    @Test("A scheme change still applies after a hard reload")
    func schemeChangeSurvivesHardReload() throws {
        let harness = try harness()
        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)
        harness.reload(soft: false)

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(harness.backgroundHex == ThemeBackground.oneHalfLight)
    }

    /// Documents *why* `reloadConfig(soft:)` builds a fresh config instead of
    /// reusing the live one, and why a soft reload re-reads nothing.
    ///
    /// `ghostty_config_finalize` resolves a theme pair by splicing the chosen
    /// half into the config's replay history, guarded on the scheme current at
    /// the time. Loading the files again on top appends a second copy of those
    /// settings after the guarded ones, so replaying under a new scheme still
    /// lands on the first-resolved half.
    ///
    /// If libghostty ever makes repeated loads idempotent this test fails —
    /// which is the signal that `reloadConfig` can be simplified.
    @Test("Reloading files into a finalized config pins the theme")
    func reloadingIntoFinalizedConfigPinsTheme() throws {
        let harness = try harness()
        harness.reloadIntoFinalizedConfig()

        harness.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK)
        #expect(
            harness.backgroundHex == ThemeBackground.oneHalfLight,
            "libghostty now tolerates loading files into a finalized config — GhosttyRuntime.reloadConfig can be simplified"
        )
    }
}
