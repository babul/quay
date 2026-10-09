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
  → SessionBootstrap → spawn request (argv + env + cwd) + optional AskpassServer
  → GhosttySurfaceView (pty runs the tab's quay-supervisor for its whole life)
  → SupervisorClient sends "spawn this" over a per-tab socket
  → quay-supervisor forks the client as the terminal's foreground process group
       ↘ (password/passphrase auth) SSH_ASKPASS → QuayAskpass → AskpassServer → KeychainStore
```

### Sessions run under a per-tab supervisor
The pty's child is **not** ssh — it is `quay-supervisor`, a bundled helper that
lives for the tab and spawns each session on request
(`SessionBootstrap.supervisorConfig(socketPath:)`). libghostty cannot respawn a
surface's command, so this is what lets a reconnect continue on the screen the
last session left rather than clearing it.

It is the `QuayAskpass`/`AskpassServer` pattern applied to spawning: a per-tab
Unix domain socket at mode 0600, one connection accepted, the path unlinked
immediately after. The protocol is newline-delimited JSON
(`Quay/Supervisor/SupervisorProtocol.swift`, compiled into both targets):
`spawn` and `signal` in, `ready`/`spawned`/`exited`/`error` out.

Four things follow from it:

- **Session lifecycle is reported, not inferred.** The helper knows its child's
  pid and exit status, so `exited` drives `TerminalTabItem.Phase` and the retry
  cycle. `SessionConnectionProbe` is now only about the *connection* — it reads
  the client's TCP state to tell connecting from connected, and never asks what
  the foreground process group is.
- **The pty is not a command channel.** Nothing is typed into it, so between
  sessions there is no interpreter to receive a stray byte: the helper reads
  the idle terminal and discards what arrives. `forwardsUserInput` still gates
  every write path, but as UX (Space/Return reconnect, Escape stops retrying),
  not as the thing standing between a keystroke and a local shell.
- **The helper restores the terminal between sessions.** Saved `termios` back,
  then the mode resets a dead remote left behind (`Supervisor.terminalReset`).
  Without the bracketed-paste reset (`ESC[?2004l`) the next session's input
  arrives wrapped in `ESC[200~`. Leaving the alt screen must use **`ESC[?1047l`,
  never `ESC[?1049l`** — 1049 restores a *saved cursor*, which sends the cursor
  home and overwrites the scrollback this design exists to keep; 1047 only acts
  when a full-screen program actually died in there.
- **A session owns the terminal properly.** It is spawned suspended into its
  own process group, made the foreground group with `tcsetpgrp`, then
  continued — so it can read the tty, Ctrl-C reaches it, and `signal` reaches
  its whole group (which is where a self-backgrounding lftp goes to hide).
  Two traps live here. `tcsetpgrp` needs a *controlling* terminal, which on
  macOS takes `TIOCSCTTY` and is not granted by opening the tty; the helper
  claims one if nothing else has and refuses to start otherwise, because the
  only symptom is Ctrl-C quietly doing nothing. And suspend is disabled
  (`VSUSP`), since a stopped child fires no `NOTE_EXIT` and Ctrl-Z would
  otherwise freeze a tab that still claimed to be connected.

### Client behaviour lives with the client
`SFTPClient.outlivesTransport` is the flag for "this client keeps its prompt
when the connection drops, and opens one lazily" — true for lftp, false for
OpenSSH's `sftp`, which connects eagerly and exits with its transport. It
decides whether a running client counts as connected. Client quirks belong
there, not keyed on `TerminalSessionKind`.

### Transport loss is noted, never acted on
Every client carries `ServerAliveInterval`/`ServerAliveCountMax`
(`SSHCommandBuilder.commonOptionArguments`, which also reaches lftp's
`sftp:connect-program`), so a dead connection is noticed in-band and ssh and
OpenSSH `sftp` exit with it — that is the session ending, and the retry cycle
takes over. lftp keeps its prompt and reconnects on the next command, so its
session is left alone and only `TerminalTabItem.transportIsLive` changes; the
tab dot dims.

For lftp that only works because `SSHCommandBuilder.lftpInteractiveTimeouts`
replaces its shipped defaults (`net:timeout` 5 minutes, `net:max-retries` 1000,
reconnect intervals growing to 5 minutes), which are built for unattended
mirroring and at a prompt are indistinguishable from a hang — a dead host gave
a command that never returned and said nothing. Leaving detection to the client
means the client has to be configured to actually report. There is deliberately no out-of-band reachability probe and no
propagation between tabs on the same host: an earlier version asked "can a
*new* connection be made?" as a proxy for "is *this* connection alive?", and
every guard it needed was compensation for that mismatch. See
`docs/session-supervision.md` §2 before adding one back.

`SessionConnectionProbe.Peer` — the far end of the client's own socket — is
what decides connected vs connecting. `ConnectionProfile.hostname` is not an
address: it is an ssh_config alias for alias profiles, and `HostName`, `Port`,
`ProxyJump`, and `ProxyCommand` can rewrite where ssh dials for any profile.

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
| `Quay/Terminal/SessionConnectionProbe.swift` | libproc probe: whether the session client holds an established connection, and to where |
| `Quay/Supervisor/SupervisorProtocol.swift` | Wire format shared by the app and `quay-supervisor` |
| `Quay/Supervisor/SupervisorClient.swift` | Quay's end of a tab's supervisor socket |
| `QuaySupervisor/Supervisor.swift` | The bundled helper: the pty's child, spawns sessions, owns the terminal between them |
| `Quay/Tabs/SessionBootstrap.swift` | Supervisor surface config, per-attempt spawn request, session marker |
| `Quay/PTY/SSHCommandBuilder.swift` | Builds every session command line; owns `TerminalSessionKind` and `SFTPClient` |
