# Quay

<p align="center">
  <img src="quay.svg" width="128" alt="Quay logo">
</p>

<!-- TODO: hero screenshot — drop a GIF or PNG here once the UI stabilises (docs/screenshots/) -->

*A quay (/kiː/, "key") is a solid structure built along the edge of a harbor where ships come alongside to moor and unload — the place where vessels meet the shore. A fitting name for an app that's your Mac's edge, where remote hosts tie up. (Some say "kay." You do you.)*

A native macOS connection manager for SSH, built on [Ghostty](https://ghostty.org)'s terminal core (`libghostty`).

[Ghostty](https://ghostty.org) is a fantastic terminal but has no connection manager. [Tabby](https://tabby.sh) has connection management but is Electron-based — slow, heavy, and cumbersome. Quay grafts connection management onto Ghostty's terminal core: a native Swift app that stays out of the way of your CPU and battery while keeping your SSH sessions alive.

> **Status:** v0.1 in development. Multi-tab SSH sessions, login scripts, SFTP, and ssh.config host discovery are all wired end-to-end.

## Privacy

Quay makes no network calls except the SSH connections you explicitly open. There is no telemetry, no analytics, no auto-update beacon, and no crash reporting. The only data that ever leaves your machine is what `/usr/bin/ssh` sends to hosts you configure.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (Intel best-effort via Rosetta)
- Xcode 16+ (Swift 6)
- [Zig 0.15](https://ziglang.org) (`brew install zig@0.15` — Ghostty 1.3.x requires this exact line)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## First-time setup

> **v0.1 — build from source only.** There are no signed or notarized builds yet. Xcode is the only install path.

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
2. Fill in `Display name`, `Hostname`, and `Username`.
3. Pick an auth method:

   | Method | How it works |
   |---|---|
   | **OpenSSH defaults** | Tries your SSH keys, then prompts for a password in the terminal if needed |
   | **Private key** | Passes a specific key file to ssh |
   | **Private key + passphrase** | As above; reads the passphrase from your Mac's Keychain |
   | **Password** | Reads the password from your Mac's Keychain — no typing required |
   | **ssh.config alias** | Delegates entirely to a `Host` block in `~/.ssh/config` |

   **Quay never stores your passwords or keys.** Authentication is handled by your Mac — via SSH keys on disk, the system SSH agent, macOS Keychain, or 1Password if you have its [SSH agent](https://developer.1password.com/docs/ssh/agent/) enabled. The `keychain://service/account` secret reference just tells Quay where on your Mac to look; the credential itself lives in Keychain, not in Quay.

4. Hit **Save**, click the connection, terminal opens.

## Organizing connections

Connections are grouped into **folders** in the sidebar. Create a folder via the **+** menu → **New Group**, then add connections to it. Folders can be collapsed to keep the sidebar tidy.

Press **⌘L** to focus the search field and filter connections by name — results are ranked by fuzzy match so partial strings work fine.

## ~/.ssh/config hosts

Quay reads `~/.ssh/config` on launch and shows every concrete `Host` alias in a collapsible **~/.ssh/config** section at the bottom of the sidebar. Click any host to open a terminal immediately — Quay delegates entirely to the matching `Host` block, so all your existing config options (identity files, port, jump hosts, `ProxyCommand`, etc.) work without touching Quay's connection editor.

`Include` directives are followed, so split config layouts like `~/.ssh/config.d/` work out of the box. Wildcard patterns (`Host *`, `Host *.example.com`) are filtered out — only named aliases appear.

To promote a discovered host to a permanent Quay connection, right-click it → **Save to Quay**. That creates a connection profile pre-filled with the alias and lets you layer on extras like a login script, SFTP settings, or a color tag. Once saved, the host drops out of the **~/.ssh/config** section — it now lives with your other Quay connections.

## Login scripts

Login scripts automate repetitive steps that happen after the shell opens. Each step is a **match → send** pair: Quay watches the terminal output and types the `send` text as soon as the `match` string appears. Steps run in order; each times out after 30 seconds if the match never arrives.

Configure steps in the connection editor under **Login script**.

**Example: sudo with a password**

| # | Match | Send |
|---|---|---|
| 1 | `$` | `sudo -i` |
| 2 | `password` | `mysudopassword` |
| 3 | `#` | |

> **Security note:** Text in the `send` field is stored as-is in Quay's local database. Do not store passwords here if you consider them sensitive — prefer `NOPASSWD` in sudoers, an SSH certificate with forced command, or another mechanism that doesn't require embedding a password in a config file.

**Example: tail a log on connect**

| # | Match | Send |
|---|---|---|
| 1 | `$` | `tail -f /var/log/app.log` |

**Example: run a command automatically**

| # | Match | Send |
|---|---|---|
| 1 | `$` | `cd /srv/app && ./status.sh` |

## SFTP

Quay opens SFTP sessions using whichever client you select in **Settings → SFTP**. Three options are supported:

| | macOS built-in | OpenSSH (Homebrew) | lftp (Homebrew) ★ |
|---|---|---|---|
| **Install** | None | `brew install openssh` | `brew install lftp` |
| **Binary** | `/usr/bin/sftp` | `/opt/homebrew/bin/sftp` | `/opt/homebrew/bin/lftp` |
| **OpenSSH version** | Bundled (older) | Latest | n/a (own client) |
| **Directory mirror / sync** | No | No | Yes (`mirror`) |
| **Parallel transfers** | No | No | Yes |
| **Resume interrupted transfers** | No | No | Yes |
| **Scripting / automation** | No | No | Yes |
| **Colors & rich UI** | No | No | Yes |

lftp is the better choice. It mirrors directories, resumes interrupted transfers, runs jobs in parallel, and has a proper interactive shell. The built-in `sftp` client does none of that. Quay configures lftp colors automatically.

## Exporting and importing settings

Use **File → Export Settings** to save all your connection profiles and folders to a `.quaybundle` file. Use **File → Import Settings** to load one.

Two common uses: moving to a new Mac (export on the old one, import on the new), or handing a set of connections to a teammate.

The bundle contains connection names, hostnames, usernames, auth methods, and folder structure — but **never your actual passwords or keys**. Those stay in your Mac's Keychain (or wherever you keep them). If you share a bundle with someone else, they'll need to add their own credentials for any connections that use Keychain auth.

Bundles can be encrypted with a password (AES-256) on export — worth doing if you're sending one to someone else or storing it outside your machine.

## Running tests

```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test
```

Currently 26 tests across 6 suites:

- `SSHCommandBuilder` — argv assembly, shell quoting, askpass env wiring (10 tests)
- `Persistence` — SwiftData round-trips, auth reconstruction (5 tests)
- `SecretReference` — URI parsing (3 tests)
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
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting, in-scope components, and how to reach maintainers privately.

## Acknowledgements

See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md) for the full list of projects and libraries Quay builds on.

## License

MIT. See [LICENSE](LICENSE).
