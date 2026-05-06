# Security Policy

## Supported versions

Quay is pre-1.0. Only the `main` branch receives security fixes; there are no stable release branches yet.

## Reporting a vulnerability

**Please do not file public GitHub issues for security vulnerabilities.**

Use [GitHub Security Advisories](https://github.com/babul/quay/security/advisories/new) to report privately. I'll usually reply within a few days. If you haven't heard back in a week, ping me via [GitHub Discussions](https://github.com/babul/quay/discussions).

## Scope

**In scope** — vulnerabilities in Quay's own code:

- `AskpassServer` Unix domain socket IPC (secret delivery to SSH_ASKPASS helper)
- `KeychainStore` / `ReferenceResolver` — Keychain credential retrieval
- `SSHCommandBuilder` — SSH argv assembly that could expose secrets via process listing
- `SettingsBundle` export/import — AES-GCM-256 + PBKDF2 encryption
- `SecretReference` URI parsing — schemes that could allow unintended data exposure
- `QuayAskpass` helper binary — the bundled SSH_ASKPASS CLI

The threat model is documented in [`docs/secrets-architecture.md`](docs/secrets-architecture.md).

**Out of scope** — please report upstream:

- Vulnerabilities in OpenSSH (`/usr/bin/ssh`) → [openssh.com](https://www.openssh.com/security.html)
- Vulnerabilities in Ghostty / libghostty → [ghostty.org](https://ghostty.org)
- Vulnerabilities in macOS Keychain Services → [Apple Product Security](https://support.apple.com/en-us/HT201220)
