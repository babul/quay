# Quay

A native macOS connection manager for SSH, built on [Ghostty](https://ghostty.org)'s terminal core (`libghostty`).

The thesis: [Tabby](https://tabby.sh) has the best connection-manager UX in the OSS terminal space, but Electron-slow. Ghostty has the best terminal but no connection manager. Quay bridges the two.

> **Status:** v0.1 in development. Not yet usable. See [`.claude/plans/`](.claude/plans/) for the active plan.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (Intel best-effort via Rosetta)
- Xcode 16+
- [Zig](https://ziglang.org) (for building libghostty — `brew install zig`)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## First-time setup

```sh
git clone --recurse-submodules <this-repo> quay
cd quay
./scripts/bootstrap.sh
open Quay.xcodeproj
```

`bootstrap.sh` will:

1. Verify Zig + xcodegen are installed.
2. Build `libghostty` from the vendored submodule into `Frameworks/GhosttyKit.xcframework`.
3. Generate `Quay.xcodeproj` from `project.yml`.

## Layout

```
Quay/             # App target sources
QuayAskpass/      # SSH_ASKPASS helper CLI (bundled inside the .app)
QuayTests/        # Swift Testing suite
Frameworks/       # Built libghostty xcframework (gitignored)
vendor/ghostty/   # Pinned ghostty source (git submodule)
scripts/          # build-ghostty.sh, bootstrap.sh
docs/             # Architecture notes
```

## License

MIT. See [LICENSE](LICENSE).
