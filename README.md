# Quay

A native macOS connection manager for SSH, built on [Ghostty](https://ghostty.org)'s terminal core (`libghostty`).

The thesis: [Tabby](https://tabby.sh) has the best connection-manager UX in the OSS terminal space, but Electron-slow. Ghostty has the best terminal but no connection manager. Quay bridges the two.

> **Status:** v0.1 in development. Multi-tab SSH sessions are wired end-to-end: sidebar → SwiftData profile store → Keychain reference resolution → SSH_ASKPASS bridge → libghostty surface running `/usr/bin/ssh`. Splits, ssh.config import, and 1Password land in subsequent milestones.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (Intel best-effort via Rosetta)
- Xcode 16+ (Swift 6)
- [Zig 0.15](https://ziglang.org) (`brew install zig@0.15` — Ghostty 1.3.x requires this exact line)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## First-time setup

```sh
git clone --recurse-submodules <this-repo> quay
cd quay
./scripts/bootstrap.sh
open Quay.xcodeproj
```

`bootstrap.sh` will:

1. Verify `zig@0.15` and `xcodegen` are installed.
2. Initialize the `vendor/ghostty` submodule (≈300 MB).
3. Build `libghostty` from source into `Frameworks/GhosttyKit.xcframework` (5–10 min on a fresh box; instant after that thanks to the cache).
4. Generate `Quay.xcodeproj` from `project.yml`.

Then ⌘R inside Xcode launches the app.

## Adding your first connection

1. Click the **+** menu in the bottom-left of the sidebar → **New Connection…**
2. For `ssh-agent` auth: just `Display name` + `Hostname` + `Username`.
3. For `Password` or `Private key + passphrase`: paste a `keychain://service/account` URI as the secret reference. Create the entry first via:

   ```sh
   security add-generic-password -s quay -a my-host -w 'mypassword' -U
   ```
4. Hit **Save**, click the connection, terminal opens.

## Running tests

```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test
```

Currently 27 tests across 6 suites:

- `SSHCommandBuilder` — argv assembly, shell quoting, askpass env wiring (10 tests)
- `Persistence` — SwiftData round-trips, auth reconstruction (5 tests)
- `SecretReference` — URI parsing (4 tests)
- `AskpassServer + helper` — actually invokes the bundled `quay-askpass` binary against a server with a fake resolver and asserts on stdout (2 tests)
- `FuzzySearch` — sidebar search ranking (5 tests)
- `Smoke` (1 test)

## Layout

```
Quay/             App target sources
  App/            QuayApp, ContentView, AppFeature (TCA), TerminalClient
  Models/         SwiftData @Model classes
  Persistence/    ModelContainer setup
  Sidebar/        SidebarView + FuzzySearch
  ProfileEditor/  ConnectionEditor
  Tabs/           TerminalTabManager, TerminalTabItem, TerminalTabBar, SessionBootstrap
  Terminal/       GhosttyRuntime, GhosttySurfaceView + extensions, GhosttySurfaceBridge
  PTY/            SSHCommandBuilder
  Secrets/        SecretReference, KeychainStore, AskpassServer, …
QuayAskpass/      SSH_ASKPASS helper CLI (bundled inside the .app)
QuayTests/        Swift Testing suite
Frameworks/       Built libghostty xcframework (gitignored)
vendor/ghostty/   Pinned Ghostty source (git submodule)
scripts/          build-ghostty.sh, bootstrap.sh
docs/             ghostty-integration.md, secrets-architecture.md
```

## Design notes

- [`docs/ghostty-integration.md`](docs/ghostty-integration.md) — how libghostty is built, pinned, and embedded; how to bump the pin.
- [`docs/secrets-architecture.md`](docs/secrets-architecture.md) — the askpass IPC, the URI scheme, the zeroing contract, and the threat model.

## Acknowledgements

The libghostty surface architecture (per-surface `@Observable` bridge, `NSTextInputClient` IME, wakeup tick driver, occlusion handling) was drawn from [supacode](https://github.com/supabitapp/supacode), which showed how to embed libghostty naturally in a SwiftUI + Composable Architecture app.

## License

MIT. See [LICENSE](LICENSE).
