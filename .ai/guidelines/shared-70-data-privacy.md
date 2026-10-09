<!-- Managed in oss-platform: shared/guidelines/70-data-privacy.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh ~/Sandbox/oss-platform; edits here are overwritten. -->

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
