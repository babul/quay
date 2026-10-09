# Agent Instructions

Follow direct user instructions first, then this file.

The block between the `cribsheet` markers is compiled from `.ai/guidelines/`. Edit the fragments
and run `scripts/agents.sh`; never edit the block by hand.

<!-- cribsheet:begin -->
=== .ai/guidelines/010-overview.md ===

## What this project is

Quay is a native macOS SSH connection manager (macOS 15+, Apple Silicon) built on top of `libghostty` — the core of the Ghostty terminal — without shipping Ghostty's full UI. Think Tabby-style connection manager UX on a Ghostty-speed terminal engine.

A tab is not always ssh. `TerminalSessionKind` is `.ssh` or `.sftp`, and an sftp
tab runs one of three clients (`SFTPClient`: macOS built-in `sftp`, Homebrew
OpenSSH `sftp`, or `lftp`) chosen by the user in Settings. Both enums live in
`Quay/PTY/SSHCommandBuilder.swift`. The kind decides the command line; the
*client* is what the session machinery has to care about, because the three
behave differently once connected — see "Client behaviour lives with the
client" below.

=== .ai/guidelines/020-build.md ===

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

**Check `AGENTS.md` is current** (before committing any change under `.ai/guidelines/`; there is no
pre-commit hook, so this is the gate):
```sh
scripts/agents.sh check
```

The Xcode project is gitignored and generated from `project.yml` by XcodeGen. Never edit `.xcodeproj` files directly.

=== .ai/guidelines/030-architecture.md ===

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

=== .ai/guidelines/040-conventions.md ===

## Conventions

- Tests use **Swift Testing** (`@Test`, `#expect`) — not XCTest.
- `ConnectionProfile.auth` reconstructs the `SSHAuth` enum from stored fields; always go through that property rather than reading raw fields.
- Run `xcodegen generate` immediately after modifying `project.yml` **or adding/removing/renaming any source file** — the `.xcodeproj` lists files explicitly and is not committed. A new file that hasn't been regenerated in simply isn't compiled; a new test file fails silently, with the run reporting the old test count and passing.
- `GhosttyKit.xcframework` in `Frameworks/` is gitignored. Never commit it; it is rebuilt from `vendor/ghostty` via the build script.
- **Any new user-facing preference added to `AppSettingsView` must also be added to `PreferencesDTO` in `Quay/Persistence/SettingsBundle.swift`** — one optional field, one encode line, one decode line in `applyPreferences`. This keeps export/import in sync with the Settings UI. Sidebar layout and window geometry keys are intentionally excluded.

=== .ai/guidelines/050-work-tracking.md ===

## Work tracking

The shared **Tracking work in Shortcut** and **Commits** rules apply. Quay's specifics:

- Board: team **Quay** in the `myoss` workspace,
  https://app.shortcut.com/myoss/stories/space/16891
- Add the `shortcut-myoss` MCP server (Shortcut's hosted endpoint, authorized against the OSS
  workspace) with
  `claude mcp add --transport http --scope local shortcut-myoss https://mcp.shortcut.com/mcp`,
  then `/mcp` to log in. The `shortcut-aliada` and `shortcut-clayton` servers are other
  workspaces and cannot see Quay stories.
- `docs/` is for how things work and why; what is left to do, including live-verification
  checklists, lives in Shortcut. When a design
  note in `docs/` spawns implementation steps, file them as stories under an epic and link the
  note from the epic, rather than adding a plan file next to it.

=== .ai/guidelines/shared-10-tracking-work.md ===

<!-- Managed in oss-platform: shared/guidelines/10-tracking-work.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Tracking work in Shortcut

Work is tracked in Shortcut, **OSS** workspace, via the `shortcut-myoss` MCP
server. Each repo has one team, all on the "Standard" workflow:

| Repo | Team | Mention |
| --- | --- | --- |
| quay | **Quay** | `quay` |
| oss-platform | **Platform** | `platform` |

**Platform** is for cross-repo coordination and tooling only: shared guidelines, sync and status
scripts, workflow policy. A product feature that spans repos still gets one story per repo team,
related to each other; it never lives on Platform.

**A story goes on the team of the repo where the change will be made, not the repo you were
working in when you found it.** Filing on another team's board still follows the rules below:
preauthorized only when it blocks your story, otherwise ask.

- The `sc-{number}` in branch names, PR titles and commit messages *is* the story id —
  `[sc-1234]` is story 1234. Look a story up before using a number; never invent one.
  `[sc-0]` means "no story".
- **The lifecycle every team uses is Backlog → To Do → In Progress → In Review → Done.** No other states
  are used.
- **To find the next story**, search `team:<mention> !is:done`, take the highest `Priority`
  (Highest, High, Medium, Low, Lowest), and read its comments before starting — anything whose
  order matters carries a `**Sequencing:**` comment naming what must come first and why. Skip
  anything marked blocked on another story or on a product decision. The priority field is the
  source of truth; the user overrides it freely.
- Work that outlives the session — follow-up defects, deferred cleanups, review findings —
  belongs in a story, not only in the conversation. **An ordering is that kind of work too**: if
  you rank the backlog, record it on the stories before the session ends, or the next session
  re-derives it and gets a different answer.

### What you may change without asking

Creating or changing a story is outward-facing and visible to the team, so the boundary is
explicit. **Anything not named here as preauthorized needs asking first** — the lists are
examples, not an exhaustive inventory.

- **Preauthorized, on this repo's team:**
  - Moving the story you are actively working to **In Progress** when you start and
    **Done** when its work lands on the integration branch, where the automations did
    not already move it (see below), and assigning it to the user.
  - Commenting results, measurements or findings on it.
  - **Filing a discovered defect or follow-up** — a bug found while working, a review finding, a
    deferred cleanup — in To Do, and saying so. File it rather than folding it into the
    change in hand.
- **One exception on another team's board:** filing a story for work that is *blocking* a story
  you are working on (for example a missing server endpoint a client story needs), and relating
  the two. The test is that your story is already blocked; work that would merely be nice is
  planned work, so ask.
- **Ask first** — including but not limited to: creating planned work (an epic, a requested
  feature), rewriting a description, changing a title, labels, priority or estimate, deleting or
  archiving a story, touching a story you are not working on, moving anything into an unused
  state, and moving an active story *backwards*. Say which team and state you intend.

### Let the automations advance stories, then check

Shortcut's VCS handlers advance stories: a branch or commit naming a story moves it to
**In Progress**, and a merge is meant to move it to **Done**. Let them, and do
not move a story they have already moved. They have been observed not to fire for local squash
merges, so check the board after a push, and move the story by hand only when it was left
behind.

### Story ↔ commit linking

A story owns **only its own commits, branches and PRs**. They attach to a story solely through the
`sc-{number}` in the branch name, the squash commit's `[sc-{n}]`, or a PR title. That automatic
VCS link is the only legitimate way work lands on a story.

- **Never manually attach a commit or PR to a story it does not belong to.** Before adding any
  external link to a story, confirm it belongs to that exact story.
- **To connect two stories, use a related-story relation — never cross-link their work.** A
  feature that spans repos gets one story per repo, related to each other.
- **Never write another story's `sc-####` token in a commit message or PR body.** Shortcut's
  GitHub integration scans the whole text and attaches the commit or PR to every story it finds,
  so a "follow-ups" list naming other stories silently attaches this work to all of them. Refer to
  other stories by title only. These links are sticky: a pushed commit cannot be reworded, editing
  a PR body does not detach it, and there is no API to unlink — the badge has to be removed by
  hand in the Shortcut UI.

=== .ai/guidelines/shared-20-commits.md ===

<!-- Managed in oss-platform: shared/guidelines/20-commits.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Commits

### When you may commit without asking

This section is the project-level opt-in that a global "never commit without explicit
confirmation" default asks for. It overrides that default **only** on these terms.

- **Committing without asking is allowed once the change has passed a second-agent review**
  (see **Reviewing changes**). Where a repo works by squash-merging locally, the same applies to
  the squash merge. The review is a gate, not a formality: if it reports anything unresolved,
  stop and surface it instead of committing. Without a clean review, ask first.
- **The review has to have covered the exact content being committed**, not an earlier version.
  Any post-review edit means re-reviewing first; `git diff` against what the reviewer saw is the
  check. If they differ, the permission to commit without asking has lapsed.
- **The repo's own build-and-test gate must also pass** on that final content. A clean review over
  a broken build is not a pass.
- **Pushing without asking is allowed on the same terms, unless the push deploys to
  production.** The commits pushed must all be ones this session made and saw reviewed and gated,
  and the repo's pre-push hook must pass. This repo's own guidelines say which branches deploy
  to production; when they do not say, treat the push as production.
- **Still ask before:** a push that deploys to production, or that carries commits you did not
  make (check `git log @{upstream}..` before pushing); force-pushing or rewriting published
  history; tagging, releasing or uploading a build.
- Never bypass a hook: no `--no-verify`, no `-n`, no `HUSKY=0`. If a hook fails, fix the cause.
  The one exception is a release step that a repo's own guidelines document with an explicit hook
  skip for the generated release commit; follow that runbook exactly and skip nothing else.

### What goes in a commit

- Only stage files you actually changed. Never sweep unrelated files into a commit.
- Write the message for **why**, not what. Record decisions and constraints that would be
  expensive to rediscover.

### Message format

**A repo with a Shortcut team** (see **Tracking work in Shortcut**) names its stories in commits,
in the format the table below gives for the branch; check the branch name first. **A repo with no
Shortcut team** uses conventional commits everywhere, with no story tag.

| Where you commit | Format | Example |
| --- | --- | --- |
| A branch containing `sc-{n}` | Conventional commit, no story tag — the branch carries it | `fix: handle an expired session on retry` |
| The integration branch (`main` or `develop`), with a story | `[sc-{n}]` and a plain description, no conventional prefix | `[sc-1234] Add user authentication feature` |
| The integration branch, no story | `[sc-0]` and a conventional prefix | `[sc-0] chore: update dependencies` |
| Any other branch, no story | Conventional commit | `feat: add auth` |

- Wrong: `[sc-1234] fix: …` on an `sc-` branch, `fix: … [sc-1234]` anywhere, and
  `[sc-1234] feat: …` on the integration branch.
- A squash merge lands one commit on the integration branch, so it takes that format — the story
  number goes in the squash message even though the branch carried it.
- If you are committing feature work to the integration branch and no story number is known,
  stop and ask rather than defaulting to `[sc-0]`. `[sc-0]` is for genuinely system-level work.
- Commits made before these rules may use other formats; do not rewrite history to match.

=== .ai/guidelines/shared-30-branches-and-prs.md ===

<!-- Managed in oss-platform: shared/guidelines/30-branches-and-prs.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Branches and merging

### Branch naming

Branch anything non-trivial. A one-line docs fix on the integration branch is fine; anything with
a story gets a branch named `{prefix}/sc-{story-number}-{slug}`:

- **`{prefix}`** — the author's name (e.g. `babul/`) for feature work, or `feature/`, `fix/`,
  `chore/` for categorised work.
- **`sc-{story-number}`** — the Shortcut story number.
- **`{slug}`** — a short kebab-case description.

Examples: `babul/sc-1234-add-export-button`, `fix/sc-1235-sort-column`.
A hotfix with no story: `fix/{slug}`.

### Landing a branch: squash merge, no PRs

The OSS silo has one developer. The second-agent review and the repo's gate already run before
every commit, so a pull request adds ceremony and no reviewer.

- Branch, and commit there once each change is gated and reviewed (conventional format, no story
  tag; see **Commits**). Then squash-merge locally into the integration branch and delete the
  branch. **Never assume `main`**: confirm the integration branch in this repo's guidelines first.
- The squash commit takes the integration-branch format, `[sc-{n}] {description}`. Its body
  carries what a PR description would have: **why** the change exists, anything a later reader
  would otherwise have to reverse-engineer (a non-obvious root cause, why the naive fix fails),
  and what was **not** verified. Refer to other stories by title only (see **Story ↔ commit
  linking**).
- Before merging, update the integration branch from its remote, so the squash lands on what is
  actually deployed.
- Open a PR only when the user asks for one. It then takes the title `[sc-{n}] {description}`,
  and its commits keep the `sc-` branch format; do not "fix" one to match the other.

=== .ai/guidelines/shared-40-reviewing.md ===

<!-- Managed in oss-platform: shared/guidelines/40-reviewing.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Reviewing changes

### Every change gets a second-agent review

- Have a second agent review a change before proposing it for commit; an agent's own diff is not
  verification. A clean review is what permits committing without asking (see **Commits**).
- Scale the review to what changed. A Codex review covers every change. The simplifier only runs
  when code changed — skip it for docs, Markdown and config-only diffs, where it has nothing to act
  on.
- The order is **simplifier → automated gates → verification → review → commit**, so the review
  is the last thing to touch the change and sees it in the form committed. Docs and config-only
  diffs skip the simplifier and any gate that does not apply, never the review.

### The review must cover exactly what you commit

**Any edit that changes the committed content after a review — however small, however mechanical
— invalidates the review and requires a fresh one.** There is no size threshold. It applies to
changes the reviewer or the simplifier itself proposed: a proposal is not a review of its own
application. Re-review, then commit.

- The test is content, not chronology. An edit reverted to exactly the reviewed state needs no new
  review — `git diff` against what the reviewer saw is the check. Staging, and regenerating
  generated files that are not committed, change nothing and trigger nothing.
- Send it back to the same reviewing agent rather than starting a new one: it still has the
  context. Say what changed, and name the files that did not so it does not re-read them.
- Acting on a review finding is itself a post-review edit: apply the fix, rerun the gates it
  touches, and send it back for review. If you run the simplifier again after a review, anything
  it changes, or any of its proposals you act on, is a post-review edit too.
- **The repo's build-and-test gate has to cover the final content too.** Re-reviewing and
  rerunning are one step, not alternatives: an edit applied after a review is exactly the kind
  that compiles in a reviewer's head and not in the real toolchain. A docs-only edit needs no
  rebuild.
- This rule was written down after it was broken twice in one session: both times a simplifier's
  own proposal, with passing tests, was applied after the review and committed unreviewed.
  Committing without asking means nothing else catches it.

### A review is not the whole gate

- A reviewing agent reads code; it does not run the build or the tests. When code changed, the
  repo's own gate (build, tests, linters, and — for a user-visible change — exercising it for
  real, see **Verifying changes**) must pass before committing.
- A consistency review passes a document that is consistently missing something. When the
  question is "is anything absent", check the history and the actual behaviour, not just whether
  the file agrees with itself.
- When two reviewers disagree, prefer the argument that can be checked against the code over the
  one inferred from a symptom.

### Working with agents

- Run editing and reviewing agents in sequence, never in parallel on the same files — a reviewer
  reading files an editor is rewriting reviews a moving target. Agents in different repos may run
  in parallel.
- Wait for an agent's completion notification before acting on its work; checking for an OS
  process does not detect in-process subagents.
- Read every agent edit before trusting it. A simplifier once deleted a passing regression test
  and kept a failing invalid one.
- Tell a simplifier to propose test or assertion removals, never to make them. Coverage is not a
  simplification target.
- When delegating, write the task so a less capable agent can finish it without guessing: exact
  file paths, what to change, the expected behaviour and the pattern to follow — one solution,
  not a menu.
- **Redirect stdin in delegated shell commands** (`< /dev/null`). An agent's stdin is a pipe that
  never closes, and any tool that reads stdin when it is not a terminal blocks on it forever. `ls`
  was once aliased to `eza`, which does exactly that, and a Codex review told to "check the
  filesystem with `ls`" was found still running after ten hours. The shell config is fixed, but
  the redirect is the cheap defence against the next such tool. A stuck task hides in plain sight:
  grep for `codex-companion` and check its children, not just the long-lived `app-server` daemons.

### Codex review

Codex reviews the finished diff: after the simplifier, after the automated gates are green,
immediately before committing. It is there to catch what the tools cannot — a fix that will not
age well, a test that passes for the wrong reason, an edge case nobody considered.

- **Ask for a review, not for objections.** Frame it as a normal PR review: "Review this for
  correctness. Say CLEAN if you would approve it as-is. Report only defects you would block a
  merge on; list anything else separately as optional nits." Never prompt it adversarially ("be
  adversarial", "hunt for issues"): a reviewer told to produce findings always produces them, and
  the loop never converges.
- **Know when it is done.** Once findings stop being reproducible defects and become threshold
  tuning or taste — and Codex says as much — that is the all-clear.
- **Give it what it needs:** what changed and why; which gates you already ran and their results;
  and what it should not re-run. Its sandbox is read-only with no database or running site, so
  anything needing those fails there for environmental reasons it would otherwise report as
  findings.
- **Run it as a background agent through the Codex plugin.** Spawn the `codex:codex-rescue`
  agent in the background with a prompt that starts with `--wait`, then says this is a
  **read-only review: do not edit files** (otherwise it defaults to a write-capable run). Carry on
  with other work, and act on the result only when the agent's completion notification arrives —
  never poll for processes. A person can run the same review with `/codex:review`.
- **`--wait`, never `--background`, in that prompt.** The agent is already in the background;
  `--background` makes it detach Codex too, so it returns at once with only a job id and its
  completion means nothing. If that happens, `/codex:status <job>` and `/codex:result <job>`
  recover the review — run from the same working directory the agent ran in, because jobs are
  tracked per workspace.
- **If it never comes back**, it is usually the stdin hang above: look for `codex-companion` and
  its children, not the long-lived `app-server` daemons, and cancel with `/codex:cancel`.
- **Without the plugin**, fall back to the CLI in the foreground; the prompt file is its stdin, so
  it never inherits one:

  ```bash
  codex exec --sandbox read-only --skip-git-repo-check - < review-prompt.md
  ```

Fix or explicitly justify every finding, re-review what you changed, then commit.

=== .ai/guidelines/shared-50-tests.md ===

<!-- Managed in oss-platform: shared/guidelines/50-tests.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Tests that earn their place

- **Show a regression test failing without its fix:** revert the fix, run the test red, restore the
  fix, run it green. A test never seen failing has not been shown to test anything.
- **A regression test that hangs on the broken code is a defective test**, even when it passes on
  the fixed code. Revert the fix and confirm it fails *fast*, with an assertion message, not by
  burning a timeout.
- **When one change fixes several defects, revert each fix individually** and confirm exactly its
  own test fails while the others pass. Reverting them all together only shows that something
  broke.
- **Assert the narrowest claim the test actually supports.** Do not infer visibility from a size,
  centring from a width, or correctness from the absence of an error.
- **Gate the operation that supersedes, rather than racing a timer.** Acting without awaiting a
  debounced or scheduled task looks safe because the margin is large, but it is a scheduling
  assumption; when it loses, the test hangs or flakes instead of failing. Use deterministic
  ordering primitives, never sleeps.
- **Prefer injecting a seam over driving the whole app**, and prefer component boundaries that take
  plain values so they can be tested without constructing services. Keep slow end-to-end and UI
  tests few and deterministic.
- **A failing test is evidence that something is wrong, not proof of the thing it claims.** Read
  what it actually measures before acting on it.
- Do not fix unrelated failing tests as part of a targeted change; file them (see **Tracking work
  in Shortcut**).
- Confirm new test files are actually compiled and collected. A suite that goes green having
  silently skipped new tests is worse than a red one; compare the test count before and after.

=== .ai/guidelines/shared-60-verification.md ===

<!-- Managed in oss-platform: shared/guidelines/60-verification.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Verifying changes

**Any change a user can see must be exercised for real before it is committed** — in a browser for
a web surface, on the simulator or a device for a native app, by running the command for a CLI.
The user should never have to ask for this. Green tests are not evidence that a UI works. This
repo's own guidelines say how to drive it; these are the principles.

### Measure, never assume

Report numbers you actually read, not values you expect. Touch targets (44pt/44px minimum),
contrast ratios, focus rings reached with a real `Tab`/keyboard press, layout at the narrowest
supported width with no horizontal overflow, both light and dark themes, reduced motion, and a
clean console or log. Each has a cheap, specific check; run it.

### Exercise the real path, not just the render

A screenshot of an initial state proves very little. Drive the actual interaction, including the
states that only appear mid-flight or on failure — progress and cancel, validation errors, an empty
list, a slow request, a signed-out session. Where a state is hard to reach naturally, use the
component's own documented events or fixtures rather than faking its markup. Prefer real data
where it is safe, and **clean up anything created** — records, uploads, and any flag toggled to
reach a state (restore it, and say so).

### Report honestly

State what was verified, and at which viewport, device and theme. Say plainly **what the automated
suites did not cover**, so nobody assumes they proved more than they did. If something could not
be exercised, say that rather than implying it passed.

=== .ai/guidelines/shared-70-data-privacy.md ===

<!-- Managed in oss-platform: shared/guidelines/70-data-privacy.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Data privacy and the threat model

- **Everything in the OSS silo is public the moment it is pushed, and Quay holds the means to
  reach its users' SSH servers.** Assume that threat model in every repo: a committed secret,
  private hostname or credential is public at once and permanent in git history; in Quay, a
  secret-handling defect exposes every server its users connect to.
- **PII is fail-closed.** Never disclose personally identifiable information (emails, phone
  numbers, names tied to them) in an API response, UI, log, analytics event or public page
  without explicit authorization. Default to masking or omitting; widen visibility only for the
  subject themselves or an authorized role. A missing authorization context means **hide**, not
  **reveal**. Never widen a server response to make a client screen easier.
- **Secrets never go in committed code, docs, story descriptions or PR bodies** — not as examples,
  not as `env()` fallbacks. If you find one committed, treat it as compromised: file a story for
  rotation rather than quietly deleting it, because it stays in git history.
- Do not print credential files (`.env`, `~/.npmrc`, keychains) to inspect them; read only the
  key you need, and mask the value.

=== .ai/guidelines/shared-90-agent-files.md ===

<!-- Managed in oss-platform: shared/guidelines/90-agent-files.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## How this AGENTS.md is built

- **In a Laravel repo, use Laravel Boost instead of cribsheet.** Boost reads the same
  `.ai/guidelines/` fragments, `shared-*.md` included, and regenerates its
  `<laravel-boost-guidelines>` block in `AGENTS.md`: run
  `php artisan boost:update --no-interaction` after editing a fragment. Never run cribsheet
  there and never edit that block by hand. Never add a `CLAUDE.md` either: Claude Code would
  read it instead of `AGENTS.md`, and Boost would start writing the guidelines into it. Every
  cribsheet instruction in this section applies only to repos without Boost.
- Without Boost, `AGENTS.md` is compiled by **cribsheet** from the fragments in
  `.ai/guidelines/`, between the `<!-- cribsheet:begin -->` and `<!-- cribsheet:end sha=… -->`
  markers. Edit a fragment, never the compiled block, then recompile and commit both. Text
  outside the markers is hand-written and never touched by the compiler.
- `shared-*.md` fragments are copies of the silo guidelines in `oss-platform/shared/guidelines/`,
  which are filled in from the shared guidelines in `~/.agents/shared-guidelines/`. Change a shared
  rule there and run the `guideline-sync` skill; never edit a repo's copy. Rules specific to one
  repo go in that repo's own numbered fragments, which may add to a shared rule but must not
  contradict it.
- A rule belongs in the shared set only if it holds in every repo without naming a file, command
  or branch specific to one of them.
- **Put each rule at the highest level where it holds**: the shared guidelines for every silo, the
  silo guidelines for one silo, a repo's own fragments for one repo. A lower level states only its
  exceptions and additions, never a copy of a rule above it.
- cribsheet is the local checkout at `~/Sandbox/cribsheet`, run with bun:
  `bun ~/Sandbox/cribsheet/bin/cribsheet.js` to compile and `… check` to verify. The
  `cribsheet` package on npm is only a name placeholder: never install it or `npx` it.
- `check` exits 1 when the output is stale (recompile) and 2 when the block was edited by hand. On a
  2, cribsheet prints how the block differs from the fragments. Move the hand edit into the right
  fragment and recompile: once the block matches, cribsheet keeps its content and updates the `sha`.
  `--force` discards the edit; use it only when that is the intent.
- Where a repo uses a formatter, `AGENTS.md` is excluded from it (for Prettier, in
  `.prettierignore`), because reformatting the block breaks its hash. Do not add a `CLAUDE.md`
  that duplicates it.
<!-- cribsheet:end sha=58b1136858d4 -->
