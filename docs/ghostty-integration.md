# libghostty Integration

How Quay embeds [Ghostty](https://ghostty.org)'s terminal core, and how to keep the integration healthy across upstream churn.

## Why we vendor + build

There is no public Swift Package distribution of `libghostty`. The C API is alpha (Mitchell Hashimoto's [Sept 2025 blog](https://mitchellh.com/writing/libghostty-is-coming): *"public alpha (not promising API stability)"*). All known embedders compile from source and pin to a specific commit.

We do the same: `vendor/ghostty` is a git submodule pinned to a known-good SHA, and `scripts/build-ghostty.sh` compiles it into `Frameworks/GhosttyKit.xcframework`.

## Toolchain pin

| Tool | Version | Why |
|---|---|---|
| Zig | **0.16.x** (`brew install zig@0.16`) | Ghostty declares `minimum_zig_version = "0.16.0"`. Both older and newer series fail at compile time. |
| Xcode | 16+ | Swift 6, Swift Testing, `bundle.unit-test` target type. |

`scripts/build-ghostty.sh` holds the required series in a single `ZIG_SERIES` variable. It prefers a keg-only `zig@$ZIG_SERIES` under `/opt/homebrew` or `/usr/local`, falls back to `zig` on `$PATH`, and version-checks whichever it picks. When upstream moves to a new Zig series, change `ZIG_SERIES` and this table.

## Current pin

`vendor/ghostty` → `6c30dc1bfff7e22a9198931411ae862a6bb6277b` (Ghostty `1.3.2-dev`, Aug 2026)

## Build invocation

`build-ghostty.sh` calls Ghostty's own `build.zig` with these flags:

```
zig build install \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \      # macOS host arch only
  -Drenderer=metal \
  -Dfont-backend=coretext \
  -Dapp-runtime=none \               # embeddable lib, not the GTK app
  -Demit-{exe,test-exe,bench,helpgen,docs,terminfo,termcap,themes,macos-app}=false
```

Output: `vendor/ghostty/macos/GhosttyKit.xcframework` (Ghostty's `XCFrameworkStep` writes to a static path, *not* through Zig's normal install mechanism) → copied to `Frameworks/GhosttyKit.xcframework`. The xcframework binary inside is named `libghostty-internal.a` (upstream dropped the `-fat` suffix; older notes may still reference it).

The script also stages the minimal runtime resources Quay needs into `Quay/Resources`: compiled terminfo plus Ghostty shell integration. At runtime, `GhosttyRuntime` points `GHOSTTY_RESOURCES_DIR` at the bundled `Contents/Resources/ghostty` directory before calling `ghostty_init`, which lets libghostty set `TERM=xterm-ghostty` and inject shell integration.

### Why `native` instead of `universal`

`-Dxcframework-target=universal` bundles three slices: macOS universal, iOS, and iOS Simulator. Quay only ships macOS, so the iOS slices are wasted megabytes and build time. `native` produces a single macOS slice for the host arch (arm64 on Apple Silicon).

Note that `native` does **not** avoid the Metal Toolchain. As of Xcode 26 the `metal` compiler is a separately downloadable component rather than part of the macOS SDK, and Ghostty precompiles `src/renderer/shaders/shaders.metal` into a `.metallib` for every Metal build regardless of target. See the troubleshooting table below.

The PRD lists Intel macOS as best-effort via Rosetta. If we later want a fat macOS-only slice (arm64 + x86_64) we'll need to teach Ghostty's `GhosttyXCFramework.zig` a third target value — currently the upstream only offers `native` (host) or `universal` (mac+ios).

The script caches on `(submodule SHA, script SHA)` so subsequent `bootstrap.sh` invocations are no-ops.

## Why `-Dapp-runtime=none`

Ghostty has two runtimes: `none` (embedder provides the windowing layer) and `gtk` (Linux GTK app). On macOS, the official Ghostty app uses the `none` runtime and provides its own SwiftUI/AppKit shell. Quay does the same.

## Config inheritance — Quay adopts the user's Ghostty settings

This is deliberate. If you already run Ghostty, Quay's terminal should look and behave like your Ghostty, without configuring anything twice.

`GhosttyRuntime.loadUserConfig()` layers four sources, last-write-wins:

1. `Quay/Resources/default-ghostty.conf` — bundled base, shipped in the app bundle
2. `ghostty_config_load_default_files()` — **the user's own Ghostty config**, i.e. `~/.config/ghostty/config` and `~/Library/Application Support/com.mitchellh.ghostty/config`
3. `ghostty_config_load_cli_args()`
4. `ghostty_config_load_recursive_files()` — any `config-file` includes

So the bundled file sets defaults for someone with no Ghostty install, and **a user's Ghostty config overrides every one of them**. This is not limited to `theme` — font, padding, cursor, scrollback and anything else in that file all win.

The practical consequence, which is easy to misread as a Quay bug: a setting in `default-ghostty.conf` can appear to have no effect on a machine whose Ghostty config sets the same key. Before treating that as a defect, check the user's config. Verify the effective value rather than reasoning about it — load the same sequence through libghostty and read the key back with `ghostty_config_get`.

The one case worth calling out is `theme`. Quay pushes the macOS appearance into libghostty via `ghostty_app_set_color_scheme` (see `GhosttyRuntime.setColorScheme`), which is what selects between the halves of a `theme = light:A,dark:B` pair. A user config that sets a *single* theme pins the terminal to that palette in both appearances — working as designed, not a light/dark bug.

## Config reloads — never load files into a finalized config

`ghostty_config_load_*` is additive, and `ghostty_config_finalize` is not idempotent for `theme`. Finalize resolves a `theme = light:A,dark:B` pair by loading the chosen half's settings and splicing them into the config's replay history as steps guarded on the scheme that was current at the time. Loading the config files *again* into that same already-finalized `ghostty_config_t` appends a second, unguarded-then-reguarded copy of those settings after the conditional ones, so replaying the history under a new scheme still ends on the first-resolved palette. The pair silently stops flipping.

The rules that follow, both implemented in `GhosttyRuntime.reloadConfig(soft:)`:

- **Honor the `soft` flag on `GHOSTTY_ACTION_RELOAD_CONFIG`.** libghostty sends `soft = true` when only its conditional state changed — an appearance switch is the usual trigger. It is asking for the *existing* config to be re-resolved, not re-read. Just call `ghostty_app_update_config`; it applies the app's conditional state and hands the resolved config back through a `config_change` action.
- **A hard reload builds a fresh `ghostty_config_t`.** Load and finalize into a new object, then swap it in — never layer onto the live one.

`ghostty_app_update_config` delivers that `config_change` action re-entrantly, before it returns. Since Quay's handler swaps `GhosttyRuntime.config` out from under the call, `updateAppConfig()` keeps the pointer it passed alive until libghostty is done with it.

To verify appearance behavior without launching the app, link `libghostty-internal.a` into a small C harness, replay the same call sequence, and read `background` back with `ghostty_config_get` after each step. That is how this was diagnosed; reasoning about the replay semantics from the outside is unreliable.

## Swift import path

The xcframework ships `module.modulemap` declaring `module GhosttyKit { umbrella header "ghostty.h" }`. Swift code imports it directly:

```swift
import GhosttyKit
// then call ghostty_app_new(...), ghostty_surface_new(...), etc.
```

There is also a `Quay/Quay-Bridging-Header.h` configured as the project's bridging header. It is currently a conditional fallback (`#if __has_include(<GhosttyKit/ghostty.h>)`) and exists only so the project compiles before `Frameworks/GhosttyKit.xcframework` has been built. Prefer `import GhosttyKit` in production code.

## Bumping the pin

1. `cd vendor/ghostty && git fetch && git checkout <new-sha>`
2. `cd ../.. && ./scripts/build-ghostty.sh` — verify it still builds.
3. Run the smoke test (Step 2 in the v0.1 plan): launch the app, confirm a libghostty surface renders and echoes input.
4. If the C API changed, refactor the affected files in `Quay/Terminal/` first.
5. Commit the submodule bump separately: `chore(ghostty): bump pin to <short-sha>`.
6. Update the "Current pin" line above with the new SHA + Ghostty version.

## API stability ranking (worth knowing before bumping)

In rough order of how often the embedder-facing surface changes:

1. **Surface lifecycle** (`ghostty_surface_new`, `_free`, `_resize`, `_draw`) — most stable.
2. **Input encoding** (`ghostty_surface_key`, mouse callbacks) — moderately stable.
3. **Config loading** (`ghostty_config_*`) — in flux; expect rename churn.
4. **Effect-handler callbacks** (PTY write-back, OSC dispatch, link clicks) — most volatile.

Keep the bridging surface narrow (one or two Swift files in `Quay/Terminal/`) so an API bump is a bounded refactor, not a re-architecture.

## When `build-ghostty.sh` fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode 26+ ships the `metal` compiler as an optional component; Ghostty precompiles its shaders into a `.metallib` | `xcodebuild -downloadComponent MetalToolchain`. Independent of the ghostty pin — a fresh Xcode install always needs this. |
| `error: Your Zig version vX.Y.Z does not meet the required build version` | Resolved `zig` is off the required series | Check `vendor/ghostty/build.zig.zon` for `minimum_zig_version`, install that series, and update `ZIG_SERIES` in `build-ghostty.sh` |
| `error: 'foo' must be a function` (or similar Zig type error in `build.zig`) | Same cause — a Zig series mismatch the version gate did not catch | As above |
| `the dependency manifest does not contain hash for 'foo'` | Stale `zig-cache` | `rm -rf vendor/ghostty/.zig-cache vendor/ghostty/zig-out` and rerun |
| Fetched dep returns 404 | Upstream `deps.files.ghostty.org` rotated a tarball | Bump the submodule to a newer SHA; old build.zig.zon entries get GC'd |
| Build succeeds but `find … GhosttyKit.xcframework` returns nothing | Upstream renamed the output dir | `find vendor/ghostty/zig-out -type d -name '*.xcframework'` and update the `SRC=` line in `build-ghostty.sh` |

## References

- [Mitchell Hashimoto — *Libghostty Is Coming*](https://mitchellh.com/writing/libghostty-is-coming) (Sept 2025)
- [Kytos — *A Native macOS Terminal Built on Ghostty*](https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/) (Mar 2026) — first publicly documented Swift+Metal embedder
- [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — open-source Swift/AppKit embedder, useful for cribbing the bridging-header pattern
- [`vendor/ghostty/include/ghostty.h`](../vendor/ghostty/include/ghostty.h) — canonical C API
