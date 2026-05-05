# libghostty Integration

How Quay embeds [Ghostty](https://ghostty.org)'s terminal core, and how to keep the integration healthy across upstream churn.

## Why we vendor + build

There is no public Swift Package distribution of `libghostty`. The C ABI is alpha (Mitchell Hashimoto's [Sept 2025 blog](https://mitchellh.com/writing/libghostty-is-coming): *"public alpha (not promising API stability)"*). All known embedders compile from source and pin to a specific commit.

We do the same: `vendor/ghostty` is a git submodule pinned to a known-good SHA, and `scripts/build-ghostty.sh` compiles it into `Frameworks/GhosttyKit.xcframework`.

## Toolchain pin

| Tool | Version | Why |
|---|---|---|
| Zig | **0.15.x** (`brew install zig@0.15`) | Ghostty 1.3.x has `requireZig("0.15.2")`. Zig 0.16 fails at compile time. |
| Xcode | 16+ | Swift 6, Swift Testing, `bundle.unit-test` target type. |

`scripts/build-ghostty.sh` resolves `zig` from `/opt/homebrew/opt/zig@0.15` first, falling back to `$PATH` only if the version is 0.15.x. This guards against a `brew upgrade` accidentally yanking the wrong Zig under us.

## Current pin

`vendor/ghostty` → `1547dd667ab6d1f4ebcdc7282adc54c95752ee67` (Ghostty `1.3.2-dev`, May 2026)

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

Output: `vendor/ghostty/macos/GhosttyKit.xcframework` (Ghostty's `XCFrameworkStep` writes to a static path, *not* through Zig's normal install mechanism) → copied to `Frameworks/GhosttyKit.xcframework`. The xcframework binary inside is named `libghostty-internal-fat.a` regardless of slice count.

The script also stages the minimal runtime resources Quay needs into `Quay/Resources`: compiled terminfo plus Ghostty shell integration. At runtime, `GhosttyRuntime` points `GHOSTTY_RESOURCES_DIR` at the bundled `Contents/Resources/ghostty` directory before calling `ghostty_init`, which lets libghostty set `TERM=xterm-ghostty` and inject shell integration.

### Why `native` instead of `universal`

`-Dxcframework-target=universal` bundles three slices: macOS universal, iOS, and iOS Simulator. Quay only ships macOS, so the iOS slices are wasted megabytes — and they require the Metal Toolchain installed for iOS shader compilation, which adds ~700MB to the Xcode footprint. `native` skips all of that and produces a single macOS slice for the host arch (arm64 on Apple Silicon).

The PRD lists Intel macOS as best-effort via Rosetta. If we later want a fat macOS-only slice (arm64 + x86_64) we'll need to teach Ghostty's `GhosttyXCFramework.zig` a third target value — currently the upstream only offers `native` (host) or `universal` (mac+ios).

The script caches on `(submodule SHA, script SHA)` so subsequent `bootstrap.sh` invocations are no-ops.

## Why `-Dapp-runtime=none`

Ghostty has two runtimes: `none` (embedder provides the windowing layer) and `gtk` (Linux GTK app). On macOS, the official Ghostty app uses the `none` runtime and provides its own SwiftUI/AppKit shell. Quay does the same.

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
| `error: Your Zig version v0.16.0 does not meet the required build version` | `zig` from `$PATH` is 0.16+ | `brew install zig@0.15`; the script will pick the keg-only path automatically |
| `error: 'foo' must be a function` (or similar Zig type error in `build.zig`) | Submodule pin uses a `build.zig` that needs a different Zig minor | Check `vendor/ghostty/build.zig.zon` for `minimum_zig_version`; install the matching `zig@x.y` keg |
| `the dependency manifest does not contain hash for 'foo'` | Stale `zig-cache` | `rm -rf vendor/ghostty/.zig-cache vendor/ghostty/zig-out` and rerun |
| Fetched dep returns 404 | Upstream `deps.files.ghostty.org` rotated a tarball | Bump the submodule to a newer SHA; old build.zig.zon entries get GC'd |
| Build succeeds but `find … GhosttyKit.xcframework` returns nothing | Upstream renamed the output dir | `find vendor/ghostty/zig-out -type d -name '*.xcframework'` and update the `SRC=` line in `build-ghostty.sh` |

## References

- [Mitchell Hashimoto — *Libghostty Is Coming*](https://mitchellh.com/writing/libghostty-is-coming) (Sept 2025)
- [Kytos — *A Native macOS Terminal Built on Ghostty*](https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/) (Mar 2026) — first publicly documented Swift+Metal embedder
- [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — open-source Swift/AppKit embedder, useful for cribbing the bridging-header pattern
- [`vendor/ghostty/include/ghostty.h`](../vendor/ghostty/include/ghostty.h) — canonical C API
