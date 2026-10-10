<!-- Adopted from the fragment library (data-privacy), 2026-10-10. Owned by this repo: edit freely. -->

## Data privacy

- **Quay holds the means to reach its users' SSH servers.** A defect in its secret handling
  (askpass socket, Keychain, settings export; see **Secret handling** under Architecture and
  `docs/secrets-architecture.md`) exposes the credentials of every server its users connect to,
  and a secret or private hostname committed here is public at once and permanent in git history.
- **PII is fail-closed.** Never disclose personal information (emails, phone numbers, names tied to
  them) in an API response, UI, log, analytics event or public page without explicit
  authorization. Default to masking or omitting; widen visibility only for the subject or an
  authorized role. A missing authorization context means **hide**, not **reveal**. Never widen a
  server response to make a client screen easier.
- **Secrets never go in committed code, docs, story descriptions or PR bodies,** not as examples
  and not as `env()` fallbacks. Treat a committed secret as compromised: file it for rotation
  rather than quietly deleting it, because it stays in git history.
- **Never print a credential file** (`.env`, `~/.npmrc`, keychains) to inspect it. Read only the key
  you need, and mask the value.
