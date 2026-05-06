# Acknowledgments

Quay builds on a few open-source projects. Particular thanks to:

- **[Ghostty](https://github.com/ghostty-org/ghostty)** by Mitchell Hashimoto and contributors — Quay's terminal rendering is powered by libghostty, the embeddable terminal core extracted from Ghostty. Quay only exists because the Ghostty team chose to make libghostty embeddable in the first place.
- **[supacode](https://github.com/supabitapp/supacode)** by Khoi and contributors — a reference for how to embed libghostty in a native Swift application. Quay's libghostty integration was implemented independently (see [`docs/supacode-independence-audit.md`](docs/supacode-independence-audit.md)), but supacode was a valuable resource for understanding the embedding patterns.
- **[Tabby](https://github.com/Eugeny/tabby)** by Eugene Pankov and contributors — the inspiration for Quay's connection management UX. The connection tree, login script editor, and snippet workflow ideas all came from using Tabby.

Quay also depends on:

- **The Composable Architecture** by Point-Free — the state management foundation for Quay's SwiftUI layer.
- **Apple's SwiftUI, AppKit, SwiftData, and Keychain Services** — the platform Quay is built on.
- **OpenSSH** — the SSH client Quay shells out to for connections.
- **1Password** — SSH keys stored in 1Password are available automatically when the 1Password SSH agent is enabled.
