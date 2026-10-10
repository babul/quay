## Conventions

- Tests use **Swift Testing** (`@Test`, `#expect`) — not XCTest.
- `ConnectionProfile.auth` reconstructs the `SSHAuth` enum from stored fields; always go through that property rather than reading raw fields.
- Run `xcodegen generate` immediately after modifying `project.yml` **or adding/removing/renaming any source file** — the `.xcodeproj` lists files explicitly and is not committed. A new file that hasn't been regenerated in simply isn't compiled; a new test file fails silently, with the run reporting the old test count and passing.
- `GhosttyKit.xcframework` in `Frameworks/` is gitignored. Never commit it; it is rebuilt from `vendor/ghostty` via the build script.
- **Any new user-facing preference added to `AppSettingsView` must also be added to `PreferencesDTO` in `Quay/Persistence/SettingsBundle.swift`** — one optional field, one encode line, one decode line in `applyPreferences`. This keeps export/import in sync with the Settings UI. Sidebar layout and window geometry keys are intentionally excluded.
- **The repo is held to an external security baseline,** checked weekly from outside this repo. Keep `.github/dependabot.yml` and `SECURITY.md`, and don't leave Dependabot alerts or PRs open for long. Repository settings (secret scanning, push protection, private vulnerability reporting, the `main` ruleset, delete-branch-on-merge) are managed by that baseline; don't change them by hand.
