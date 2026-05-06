# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Quay is a native macOS SSH connection manager (macOS 14+, Apple Silicon) built on top of `libghostty` — the core of the Ghostty terminal — without shipping Ghostty's full UI. Think Tabby-style connection manager UX on a Ghostty-speed terminal engine.

## Build commands

**First-time setup** (requires Xcode 16+, `zig@0.15`, `xcodegen`):
```sh
./scripts/bootstrap.sh
open Quay.xcodeproj
```

**Regenerate Xcode project** (after changing `project.yml`):
```sh
xcodegen generate
```

**Run tests:**
```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test
```

**Run a single test suite** (e.g., SSHCommandBuilderTests):
```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test -only-testing:QuayTests/SSHCommandBuilderTests
```

**Rebuild libghostty** (only needed when bumping the ghostty submodule):
```sh
./scripts/build-ghostty.sh
```

The Xcode project is gitignored and generated from `project.yml` by XcodeGen. Never edit `.xcodeproj` files directly.

## Architecture

### Concurrency model
Swift 6 strict concurrency is enforced (`SWIFT_STRICT_CONCURRENCY=complete`). All UI code and libghostty callbacks run on `@MainActor`. C callbacks from libghostty are `nonisolated static` functions that use `MainActor.assumeIsolated` (they are always invoked on the main thread by libghostty). Async/await is used in `TerminalTabItem.run()` for PTY event polling.

### State management — two layers
- **Top-level app state** uses Composable Architecture (TCA): `AppFeature` reducer + `TerminalClient` DependencyKey. TCA is the boundary between sidebar/tab actions and the terminal subsystem.
- **Low-latency paths** (tab state, surface render state) use `@Observable` singletons (`TerminalTabManager`, `GhosttySurfaceBridge`) directly, bypassing TCA to avoid view update overhead.

### libghostty integration (`Quay/Terminal/`)
`GhosttyRuntime` is a per-process singleton wrapping `ghostty_app_t`. It owns a weak-ref registry of `GhosttySurfaceBridge` instances (one per tab) to avoid retain cycles. `GhosttySurfaceView` is an `NSView` subclass implementing `NSTextInputClient` for IME; it is wrapped by `GhosttyTerminalView` for SwiftUI via `NSViewRepresentable`. See `docs/ghostty-integration.md` for the build/pin/bump process.

### Secret handling — zero plaintext (`Quay/Secrets/`)
Credentials are never stored as plaintext — only as reference URIs (`keychain://service/account`). `AskpassServer` is a Unix domain socket server at `$TMPDIR/quay-askpass-<uuid>.sock` (mode 0600) that resolves URIs at connection time and pipes the secret to the bundled `QuayAskpass` CLI (the SSH_ASKPASS helper). The socket is unlinked after one use. The only place Quay writes to Keychain is the login-script step lock action — writes are deferred until profile save. See `docs/secrets-architecture.md` for the full threat model.

### Connection data flow
```
ConnectionProfile (SwiftData)
  → TerminalTabManager.openOrSelectTab()
  → SessionBootstrap → GhosttySurfaceConfig + optional AskpassServer
  → GhosttyRuntime.spawn(SSHCommand) → libghostty fork+exec /usr/bin/ssh
       ↘ (password/passphrase auth) SSH_ASKPASS → QuayAskpass → AskpassServer → KeychainStore
```

### Persistence (`Quay/Persistence/`)
SwiftData `ModelContainer` stored at `~/Library/Application Support/<bundleID>/Quay.store`. CloudKit sync is intentionally disabled for v0.1. Settings export/import uses AES-GCM-256 encryption with PBKDF2-HMAC-SHA256 key derivation (`SettingsBundle.swift`). SSH credentials and key passphrases are exported only as their reference URIs. Locked login-script step values are resolved to plaintext inside the bundle so it's portable to a new machine; the bundle password is what protects them.

### Key files
| File | Purpose |
|------|---------|
| `project.yml` | XcodeGen project definition — single source of truth for targets, dependencies, build settings |
| `Quay/App/AppFeature.swift` | Top-level TCA reducer |
| `Quay/App/TerminalClient.swift` | TCA DependencyKey facade between reducers and terminal subsystem |
| `Quay/Models/ConnectionProfile.swift` | SwiftData `@Model` with `AuthMethod` enum and `sshTarget` computed property |
| `Quay/Tabs/TerminalTabManager.swift` | `@Observable @MainActor` singleton managing all live SSH tabs |
| `Quay/Terminal/GhosttyRuntime.swift` | libghostty app singleton, surface registry, config reload |
| `Quay/Terminal/GhosttySurfaceBridge.swift` | Per-surface `@Observable` bridge between C callbacks and Swift |
| `Quay/Secrets/AskpassServer.swift` | Unix domain socket secret delivery to SSH_ASKPASS |

## Conventions

- Tests use **Swift Testing** (`@Test`, `#expect`) — not XCTest.
- `ConnectionProfile.auth` reconstructs the `SSHAuth` enum from stored fields; always go through that property rather than reading raw fields.
- When modifying `project.yml`, run `xcodegen generate` immediately — the `.xcodeproj` is not committed.
- `GhosttyKit.xcframework` in `Frameworks/` is gitignored. Never commit it; it is rebuilt from `vendor/ghostty` via the build script.
- **Any new user-facing preference added to `AppSettingsView` must also be added to `PreferencesDTO` in `Quay/Persistence/SettingsBundle.swift`** — one optional field, one encode line, one decode line in `applyPreferences`. This keeps export/import in sync with the Settings UI. Sidebar layout and window geometry keys are intentionally excluded.
