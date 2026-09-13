# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Quay is a native macOS SSH connection manager (macOS 15+, Apple Silicon) built on top of `libghostty` — the core of the Ghostty terminal — without shipping Ghostty's full UI. Think Tabby-style connection manager UX on a Ghostty-speed terminal engine.

A tab is not always ssh. `TerminalSessionKind` is `.ssh` or `.sftp`, and an sftp
tab runs one of three clients (`SFTPClient`: macOS built-in `sftp`, Homebrew
OpenSSH `sftp`, or `lftp`) chosen by the user in Settings. Both enums live in
`Quay/PTY/SSHCommandBuilder.swift`. The kind decides the command line; the
*client* is what the session machinery has to care about, because the three
behave differently once connected — see "Client behaviour lives with the
client" below.

## Build commands

**First-time setup** (requires Xcode 16+, `zig` 0.16.x, `xcodegen`):
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
`GhosttyRuntime` is a per-process singleton wrapping `ghostty_app_t`. It owns a weak-ref registry of `GhosttySurfaceBridge` instances (one per tab) to avoid retain cycles. `GhosttySurfaceView` is an `NSView` subclass implementing `NSTextInputClient` for IME; surfaces are hosted for SwiftUI by `TerminalSurfaceHostsView` in `ContentView`, which keeps every tab's surface attached and orders the selected one frontmost. See `docs/ghostty-integration.md` for the build/pin/bump process.

**Quay intentionally inherits the user's own Ghostty config.** `loadUserConfig()` loads `Quay/Resources/default-ghostty.conf` first, then `ghostty_config_load_default_files()` — so anything in `~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config` overrides the bundled defaults. A bundled setting appearing to have no effect is usually this, not a bug; check the user's Ghostty config before investigating. See "Config inheritance" in `docs/ghostty-integration.md`.

### Secret handling — zero plaintext (`Quay/Secrets/`)
Credentials are never stored as plaintext — only as reference URIs (`keychain://service/account`). `AskpassServer` is a Unix domain socket server at `$TMPDIR/quay-askpass-<uuid>.sock` (mode 0600) that resolves URIs at connection time and pipes the secret to the bundled `QuayAskpass` CLI (the SSH_ASKPASS helper). The socket is unlinked after one use. The only place Quay writes to Keychain is the login-script step lock action — writes are deferred until profile save. See `docs/secrets-architecture.md` for the full threat model.

### Connection data flow
```
ConnectionProfile (SwiftData)
  → TerminalTabManager.openOrSelectTab()
  → SessionBootstrap → host-shell GhosttySurfaceConfig + command line + optional AskpassServer
  → GhosttySurfaceView (pty runs the tab's host shell for its whole life)
  → TerminalTabItem types the ssh command line into that shell
       ↘ (password/passphrase auth) SSH_ASKPASS → QuayAskpass → AskpassServer → KeychainStore
```

### Sessions run inside a per-tab host shell
The pty's child is **not** ssh — it is a quiet local shell that lives for the
tab (`SessionBootstrap.hostShellCommand()`), and each session is *typed into*
it. libghostty cannot respawn a surface's command, so this is what lets a
reconnect continue on the screen the last session left rather than clearing it.

Three consequences worth knowing before changing anything here:

- **Session lifecycle is observed, not reported.** The pty's child no longer
  exits when a session ends, so `SessionConnectionProbe` polls the pty's
  foreground process group (libproc) for the client (`ssh`/`sftp`) and its TCP
  state. That is what drives `TerminalTabItem.Phase` and the retry cycle.
- **Input must be gated.** Between sessions the pty belongs to the *local*
  shell, so anything typed or pasted would run on this machine.
  `GhosttySurfaceView.forwardsUserInput` gates every write path (keys, IME,
  paste, Services, middle-click, snippets, login scripts) and fails closed.
  Use `sendUserInput(_:appendReturn:)` rather than reaching for the bridge.
- **The host shell's `PS1` is load-bearing.** It prints nothing visible; it
  resets terminal modes a dead remote left behind. Without the bracketed-paste
  reset (`ESC[?2004l`) the next typed command arrives wrapped in `ESC[200~` and
  the shell runs `00~/usr/bin/ssh`. Leaving the alt screen must use
  **`ESC[?1047l`, never `ESC[?1049l`** — 1049 restores a *saved cursor*, which
  sends the cursor home and overwrites the scrollback this design exists to
  keep; 1047 only acts when a full-screen program actually died in there.
- **`stty` is load-bearing twice over.** `stty -echo` in the shell command hides
  Quay's typed command *and* is how the tab detects the shell is ready
  (`tcgetattr` ECHO). Each session's command line then re-enables echo for the
  session — sftp and lftp show nothing as you type without it — and quiets it
  again afterwards.

### The host shell is a stopgap, and these are its consequences
libghostty cannot respawn a surface's command, so sessions are *typed into a
tty*. That makes the pty a command channel, and most of the machinery around it
is compensation for that one fact:

- the shell must be the pty's foreground process group before anything is typed,
  or a local program that grabbed the terminal eats every command;
- a session ending needs two consecutive polls to agree, because the typed line
  is a *list* (`stty echo; …; <client>; stty sane -echo`) and the foreground
  group legitimately flickers between its items;
- the tty's input queue is flushed when a session ends, since bytes written for
  a dead session are otherwise read and run by the host shell — that is how a
  login script's keystrokes once started a *local* `htop`;
- login-script steps and snippets go through `sendAutomatedInput`, which
  requires an established session: a step's value may be a resolved secret.

A bundled supervisor helper — the `QuayAskpass`/`AskpassServer` pattern applied
to spawning, a process that accepts "spawn this" over a socket and cannot be fed
keystrokes — removes all four by construction. Prefer that over adding a fifth
compensation here.

### Client behaviour lives with the client
`SFTPClient.outlivesTransport` is the flag for "this client keeps its prompt
when the connection drops, and opens one lazily" — true for lftp, false for
OpenSSH's `sftp`, which connects eagerly and exits with its transport. It
decides whether a running client counts as connected and whether the host is
probed when the transport goes missing (`HostReachability`). Client quirks
belong there, not keyed on `TerminalSessionKind`.

### Reachability probes the socket's peer, never the profile's hostname
`HostReachability` is destructive — a negative answer tears the session down —
so it is only ever pointed at an address a session was actually seen connected
to, read from the client's own socket (`SessionConnectionProbe.Peer`, remembered
as `lastKnownPeer`). `ConnectionProfile.hostname` is not that address: it is an
ssh_config alias for alias profiles, and `HostName`, `Port`, `ProxyJump`, and
`ProxyCommand` can rewrite where ssh dials for any profile. Probing it reports a
healthy session dead. Two guards follow from the same fact — a probe is slow and
its answer can be stale: "unreachable" must be confirmed twice
(`reachabilityConfirmations`, since a host refusing *new* connections while
serving existing ones looks identical to a dead one), and the evidence that
prompted the check is rechecked between rounds.

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
| `Quay/Terminal/SessionConnectionProbe.swift` | libproc probe: what the pty's foreground process group is doing |
| `Quay/Tabs/SessionBootstrap.swift` | Host-shell command, typed session command line, session marker |
| `Quay/PTY/SSHCommandBuilder.swift` | Builds every session command line; owns `TerminalSessionKind` and `SFTPClient` |

## Conventions

- Tests use **Swift Testing** (`@Test`, `#expect`) — not XCTest.
- `ConnectionProfile.auth` reconstructs the `SSHAuth` enum from stored fields; always go through that property rather than reading raw fields.
- Run `xcodegen generate` immediately after modifying `project.yml` **or adding/removing/renaming any source file** — the `.xcodeproj` lists files explicitly and is not committed. A new file that hasn't been regenerated in simply isn't compiled; a new test file fails silently, with the run reporting the old test count and passing.
- `GhosttyKit.xcframework` in `Frameworks/` is gitignored. Never commit it; it is rebuilt from `vendor/ghostty` via the build script.
- **Any new user-facing preference added to `AppSettingsView` must also be added to `PreferencesDTO` in `Quay/Persistence/SettingsBundle.swift`** — one optional field, one encode line, one decode line in `applyPreferences`. This keeps export/import in sync with the Settings UI. Sidebar layout and window geometry keys are intentionally excluded.
