# Session Supervision

Why the session machinery is shaped the way it is, and why two earlier designs
were removed rather than extended.

Originally written after the sftp/lftp fix batch as a record of what was
deliberately deferred. Both changes have since landed; the reasoning is kept
because it is what stops either design from being reintroduced.

## The through-line

Quay used to have **no control channel to a session**. It had the screen and the
process table, and everything else was inference.

libghostty cannot respawn a surface's command, so a tab's pty runs one
long-lived child and sessions happen inside it. When that child was a *shell*,
the pty became a command channel, and almost every mechanism around it existed
to compensate:

| Mechanism | Compensating for | Now |
|---|---|---|
| `stty -echo` + `tcgetattr` readiness | Quay's own typed command being echoed to the screen | gone — `ready` event |
| `PS1` mode resets (`ESC[?2004l`, `ESC[?1047l`) | terminal modes a dead remote left behind | kept, moved into the helper |
| The session marker line | no other way to say which attempt produced the output below | kept, written by the helper |
| Foreground-group check before typing | a local program that grabbed the pty eating every command | gone — nothing is typed |
| Two-poll debounce on session end | the typed line being a *list*, so the group legitimately flickers | gone — `exited` event |
| `flushInput` on client loss | bytes written for a dead session being read and run locally | gone — no interpreter to read them |
| `sendAutomatedInput` | a login-script step's value may be a resolved Keychain secret | kept, now UX rather than safety |
| `forwardsUserInput` | between sessions the pty belongs to a *local* shell | kept, now UX rather than safety |

Eight mechanisms, one cause. The list was growing as more client behaviours were
discovered; it did not converge. Replacing the cause deleted five of them and
demoted two.

## 1. The supervisor helper — done

**The `QuayAskpass` / `AskpassServer` pattern, applied to spawning.**
`quay-supervisor` is the pty's child for the tab's life and accepts `spawn this`
over a Unix domain socket — the same shape already shipping for secret delivery,
with the same trust boundary: mode 0600 in `$TMPDIR`, one connection accepted,
the path unlinked immediately after.

The helper cannot execute arbitrary bytes. That is the whole point: the pty
stopped being a command channel. Session lifecycle became *reported* — the
helper knows its child's pid and exit status — instead of inferred from the
foreground process group.

### Why it was urgent rather than merely nice

`flushInput` closed most of the input race but could not close all of it. A
client could exit after `sendAutomatedInput` passed its checks but before
libghostty delivered the bytes, and `tcflush` cannot discard writes still queued
inside libghostty. Every fix in that area was a mitigation; the window narrowed
and never reached zero. A supervisor at the pty boundary is the only thing that
closes it, because there is then no interpreter on the near side to receive
stray bytes — the helper reads the idle terminal and discards what arrives.

Login-script step values may be resolved Keychain secrets, which is what made
the residual window worth spending a redesign on.

`SupervisorIntegrationTests` pins the property directly: bytes typed at an idle
terminal reach nothing, and the next session does not find them waiting.

### What the helper is careful about

- **Owning the terminal.** `tcsetpgrp` needs a *controlling* terminal, and on
  macOS a process does not get one by opening a tty — it takes an explicit
  `TIOCSCTTY`, which is what `login_tty(3)` does. libghostty's spawn already
  does it, so the helper's own claim is normally a no-op; without the claim, a
  harness that only opens the pty gets `tcsetpgrp` failing with `ENOTTY`, no
  foreground process group, and Ctrl-C silently reaching nobody. The helper
  refuses to start rather than run with a terminal it cannot control, and
  abandons a session it cannot hand the terminal to.
- **Job control.** A session is spawned suspended (`POSIX_SPAWN_START_SUSPENDED`)
  into its own process group, made the pty's foreground group with `tcsetpgrp`,
  then continued. Without the suspend there is a window where it could read the
  tty from the background and take a `SIGTTIN`.
- **Suspend is disabled** (`VSUSP`/`VDSUSP`). A stopped child fires no
  `NOTE_EXIT`, so Ctrl-Z would freeze the session while the tab still claimed
  to be connected. Suspending a foreground job offers you the shell behind it;
  there is no shell behind this one.
- **Signals.** The helper ignores `SIGTTOU`/`SIGTTIN` (or its own `tcsetpgrp`
  from the background would stop it) and `SIGINT`/`SIGQUIT`/`SIGTSTP` (a Ctrl-C
  at an idle terminal must not kill the tab). Children get them reset.
- **`SIGHUP` is not ignored.** The pty closing is how the helper learns the tab
  is gone.
- **Signals reach what a session leaves behind.** The last session's process
  group is remembered after its leader is reaped, because a client that forks
  to finish a transfer and exits is doing precisely that instead of ending —
  and the tab's escalation is tied to the attempt rather than to the leader's
  pid for the same reason. Stopping at the leader's exit is how a disconnected
  tab used to leave a live lftp behind.
- **A spawn either fully happens or does not.** A working directory that has
  gone away, a terminal that cannot be handed over, an exit watch that cannot
  be registered: each abandons the session rather than reporting a success the
  tab cannot act on. A session nothing watches for exit would become a zombie
  and every later session would be refused as "already running".
- **Terminal state.** Saved `termios` is restored after every session, then the
  mode resets. The idle terminal is put in a raw, echo-less, signal-less state,
  so a stray byte is neither shown nor acted on.

## 2. Reachability — removed

`HostReachability` asked **"can a new TCP connection be made to this address?"**
and inferred from it the answer to a different question — *"is this session's
connection still alive?"*

That mismatch was the source of every guard around it:

- **Double confirmation** (`reachabilityConfirmations`) existed because a host
  refusing *new* connections while serving existing ones — sshd restarting, a
  rate limit — is indistinguishable from a dead one.
- **Rechecking the evidence between rounds** existed because the probe is slow
  relative to the thing it describes, so its answer can be stale on arrival.
- **The `phase == .running` guard** on sibling propagation existed because
  reporting to tabs that were still attempting shot their in-flight attempts;
  with three tabs on one host, one was starved to attempt 9 while the others
  reconnected.

Three compensations for asking a proxy question.

### Every client already has the real answer

`SSHCommandBuilder.commonOptionArguments` sets `ServerAliveInterval=15` and
`ServerAliveCountMax=3`, and it reaches **all three** clients:

| Client | Path |
|---|---|
| `ssh` | `build(_:askpass:)` |
| OpenSSH `sftp` | `buildOpenSSHSFTP(_:askpass:binary:)` |
| `lftp` | `lftpSSHConnectProgram(_:)` → `set sftp:connect-program` |

That is an in-band, protocol-level check of *the actual connection*, and it
fires in ~45s. The probe only bought about 20 seconds over it.

### The destructive response served nobody cleanly

- **ssh** and **OpenSSH sftp** exit on their own when keepalives fail. They
  report the end; nothing needs to infer it.
- **lftp** does not exit — but killing it destroyed a live prompt holding local
  state (`lcd`, bookmarks, queued transfers, `set` variables). Its own defaults
  make a missing transport routine rather than a fault: `net:idle` closes an
  idle connection after 3 minutes, and the next command reconnects with backoff.

  Those same defaults are why "let the client report it" did not work at first.
  lftp ships `net:timeout` at 5 minutes and `net:max-retries` at 1000, so a dead
  host produced a command that hung silently — measured at over 75 seconds with
  no output before being killed. `SSHCommandBuilder.lftpInteractiveTimeouts`
  sets interactive values instead, and the same case now fails in about 14
  seconds naming the host and the reason. Detection in-band is only as good as
  the client's willingness to give up.

The original report behind the feature was *"sftp does not notice if the host is
unreachable"* — an **indicator** that lied. It was answered with a **teardown**.
Conflating those two was the architectural error, and unwinding it is the whole
change.

### What replaced it

`TerminalTabItem.transportIsLive`, set from the same poll that already reads the
client's TCP state. A running lftp with no transport stays `.running` and its
tab dot dims; nothing is torn down. Sibling propagation between tabs on one host
is gone entirely — its only beneficiary was lftp, and ssh and sftp notice on
their own.

### What was kept

**Reading the peer from the client's own socket.**
`SessionConnectionProbe.Peer` is correct and survives: the far end of an
established socket is the only trustworthy answer to "where is this session
actually connected?". `ConnectionProfile.hostname` is not — it is an ssh_config
alias for alias profiles, and `HostName`, `Port`, `ProxyJump`, or `ProxyCommand`
can rewrite where ssh dials for any profile. Probing it reported healthy
sessions dead.

`lastKnownPeer` was *not* kept. Its only reader was the probe, and holding a
value on the chance something wants it later is how the next version of this
gets built.

## 3. Event-driven exit notification — moot

Replacing the poll with `DispatchSource(.exit)` was considered and downgraded,
then subsumed: the helper's `kqueue` loop watches `NOTE_EXIT` on its own child
and reports it. The remaining poll is not about exit at all — it reads the
client's TCP state, which is not an event.

## Not doing: moving libproc calls off the main actor

Recorded so it is not raised again. The probe measures ~12µs and the poll
interval is 1.5s on a connected session — roughly 0.0008% of the main thread.
Peer extraction added one `inet_ntop` on one socket. There is no payoff here;
the cost of the indirection would exceed it.

## Verifying live

Neither change can be fully proven by the test suite: the suite covers the
protocol, the job control on a real pty, and the retry policy, but not a real
host going away. Against a machine that can be power-cycled or firewalled:

1. **ssh, network pulled** — the tab reads Disconnected within ~45s
   (`ServerAliveInterval=15` × `ServerAliveCountMax=3`) and starts retrying.
2. **OpenSSH sftp, network pulled** — same.
3. **lftp at an idle prompt, network pulled** — the dot dims, the prompt stays,
   nothing is killed. Run `ls`: it must *fail within ~15s naming the host*, not
   hang (see `lftpInteractiveTimeouts`; with lftp's own defaults this hung with
   no output for over 75s, which is the bug that made "the client reports it"
   ring hollow). Restore the network and run `ls` again: lftp reconnects and the
   dot goes solid.
4. **lftp left idle past 3 minutes with the network up** — the dot dims
   (`net:idle`) and `ls` reconnects. This is the case the old design misread as
   an outage and tore down.
5. **Three tabs on one host, host rebooted** — each reconnects on its own
   schedule; no tab is starved by another's report.
6. **Password and passphrase auth, and Touch ID** — askpass under the helper.
   `SSH_ASKPASS_REQUIRE=force` means the presence of a controlling tty does not
   matter, but this is the path most worth exercising by hand.
7. **Terminal state** — kill `vim` remotely mid-session, then drop the host: the
   next marker must be visible and the scrollback intact. Enable bracketed paste
   remotely and drop: the next session must not see `ESC[200~`.
8. **lftp mid-transfer disconnect** — start a large `get`, then Disconnect. The
   escalation must actually end it.
9. **Notarization** — `codesign --verify --deep --strict` on a release archive,
   confirming `quay-supervisor` is covered like `quay-askpass`.

## What is still worth watching

- **lftp and `setsid` — a known gap.** Signals go to the session's process
  group, which covers a client that forks to background itself *within* the
  group. lftp 4.9.3 does not stay: its hangup path forks and calls `detach()`,
  which calls `setsid()`, so the survivor leaves the group and neither
  `kill(-group, …)` nor the escalation behind it can reach it. Disconnecting an
  lftp tab mid-transfer can therefore leave the transfer running.

  This is not a regression — the design it replaced followed children by pid
  and lost the same race — and it is arguably lftp doing what it advertises.
  Closing it properly means either enumerating the session's descendants before
  each escalation step (racy, since the survivor is created *by* the hangup) or
  not sending `SIGHUP` to lftp at all and escalating straight to `SIGTERM`.
  The second is cheap and probably right, but rests on whether lftp's `SIGTERM`
  path also detaches, which has not been measured. Measure before changing it.
- **The `login -flp` chain.** The helper must end up owning the pty. It refuses
  to start if stdin is not a terminal, but a future libghostty change to how the
  command is wrapped is the thing that would break this quietly.
