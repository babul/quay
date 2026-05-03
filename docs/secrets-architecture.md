# Secrets Architecture

How Quay reaches into the user's vault for SSH passwords and key passphrases without ever persisting plaintext.

## The contract

> **Quay's on-disk store contains zero plaintext secrets.** Backing it up, syncing it, or stealing the file gives an attacker reference URIs and nothing else.

## The reference URI

A `ConnectionProfile` stores secret references as URI strings. Two schemes are recognized; v0.1 implements only the first:

| Scheme | Example | Backend |
|---|---|---|
| `keychain://service/account` | `keychain://quay/cac-ash-dev-db1` | macOS Keychain Services |
| `op://vault/item/field` | `op://Personal/cac-ash-dev-db1/password` | 1Password CLI (v0.2) |

`SecretReference.parseV01` accepts the first and rejects the second with a typed error.

The reference goes in `ConnectionProfile.secretRef`. For password auth that's the password; for `.privateKeyWithPassphrase` it's the passphrase.

## Resolution flow

When the user opens a connection that needs a secret:

```
SessionView.onAppear
  ├── SSHCommandBuilder.build(target, askpass: nil)
  │     -> command string with ssh args
  ├── if auth has secretRef:
  │     ├── AskpassServer(secretURI: "keychain://...")
  │     ├── server.start()  // bind UDS at $TMPDIR/quay-askpass-<uuid>.sock, mode 0600
  │     └── rebuild SSHCommand with askpass env vars
  └── GhosttyTerminalView(config: { command, environment, ... })
        └── libghostty fork+exec /usr/bin/ssh
              └── ssh sees a password prompt -> exec quay-askpass
                    └── connect(AF_UNIX, $QUAY_ASKPASS_SOCKET)
                          └── server resolves the URI:
                                ├── KeychainStore.read(service, account)
                                │     -> SecItemCopyMatching   (Touch ID prompt
                                │        if the item ACL requires it)
                                └── write bytes back over the socket
                                      -> helper pipes to stdout
                                            -> ssh consumes as password
```

After the server's single `serveOnce()` cycle, the socket is closed and the file is `unlink()`ed. The askpass server dies when the `SessionView` disappears.

## Process boundaries

```
+-----------------------------+
| Quay.app (Swift)            |
|   AskpassServer (UDS)       |
|   KeychainStore             |
|   SensitiveBytes (memset_s) |
+--------------+--------------+
               ^ socket (chmod 0600, $TMPDIR)
               |
+--------------v--------------+      +-------------------------+
| quay-askpass (helper, CLI)  | <----+ /usr/bin/ssh             |
|   reads socket -> stdout    |      | spawned by libghostty   |
+-----------------------------+      | (PTY-owning process)    |
                                     +-------------------------+
```

The helper:
- Lives bundled at `Quay.app/Contents/MacOS/quay-askpass`.
- Is execed by OpenSSH (not by Quay) when it sees `SSH_ASKPASS=…`, `SSH_ASKPASS_REQUIRE=force`, `DISPLAY=:0`, and the process is in its own session (libghostty starts ssh under `setsid`).
- Reads `QUAY_ASKPASS_SOCKET`, opens the UDS, pipes bytes to stdout, exits.
- ~25 lines of Swift. No retries, no logging, no buffering.

## Why a Unix domain socket and not env vars or argv

- **Env vars**: would leak via `/proc`, `ps -E`, child env inheritance, etc.
- **argv**: same exposure, plus visible in shell history if logged.
- **stdin**: would require us to pre-spawn the helper ourselves; we want OpenSSH to spawn it on its own schedule (it may not call askpass at all if pubkey auth wins first).
- **UDS at `$TMPDIR/quay-askpass-<uuid>.sock` with mode 0600**: same-user-only, ephemeral, never on shared filesystems, plaintext flows over a socket the kernel deletes on `unlink`.

## Memory hygiene

`SensitiveBytes` owns a heap-allocated buffer that calls `memset_s(0)` on `dealloc`. `memset_s` is the POSIX-blessed primitive the C compiler may not optimize away.

The flow:
1. Server `accept()`s a connection.
2. Server calls `await resolve()` which returns `SensitiveBytes`.
3. `bytes.withUnsafeBytes { … }` writes the bytes to the socket.
4. The closure returns. The `SensitiveBytes` goes out of scope.
5. `deinit` zeros + deallocates the buffer.

Plaintext lifetime is bounded by the time between step 2 and step 5 — typically microseconds. We never:
- Log the secret (no `Logger.info("got: \(bytes)")`).
- Convert to `String` and store it.
- Ship it to a `Data` we keep around.

The only escape is the OS Keychain returning data that *we* don't choose how to free — `SensitiveBytes(_ data: Data)` copies into our heap and the temporary `Data` goes through Swift's normal arena.

## What we deliberately don't do (yet)

- **Cache secrets across resolutions.** Every call to the helper triggers a fresh Keychain hit. Cleaner threat model; more biometric prompts. v1.x candidate.
- **Write to Keychain or 1Password.** Quay only reads. Users create/rotate via their existing vault tooling.
- **Other backends.** HashiCorp Vault, AWS Secrets Manager, Bitwarden, Doppler — all are post-v1 candidates that plug into the `ReferenceResolver` dispatcher.
- **`op://` resolution.** Lands in v0.2.

## Audit trail

- macOS Keychain accesses are visible via `log show --predicate 'subsystem contains "securityd"'`.
- 1Password (when v0.2 lands) writes to its own audit log under `~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Caches/...`.
- Quay itself does not log secret access. Adding a per-connection access log is a v1.x candidate.

## Threat model

| Threat | Mitigation |
|---|---|
| Backup of `~/Library/Application Support/Quay/Quay.store` leaks | Store contains only reference URIs and labels; no plaintext. |
| Process inspection of Quay (`ps`, debugger) | Plaintext window is microseconds; secrets live in `SensitiveBytes` then zero. |
| Sibling-user reads askpass socket | `chmod 0600` + `$TMPDIR` (per-user on macOS). |
| Compromised Quay binary exfiltrates secrets | Out of scope — code-signing + notarization (v1.0) raise the cost of a malicious binary swap. |
| Swap-file leaks | macOS encrypts the swap; FileVault tightens it further. We don't add anything beyond what the OS provides. |
| Secret rotation in Keychain | Quay re-reads the URI on every connect — no cache, no staleness. |
