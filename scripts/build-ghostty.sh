#!/usr/bin/env bash
# build-ghostty.sh — build libghostty from the vendored submodule and stage
# the resulting xcframework at Frameworks/GhosttyKit.xcframework.
#
# Idempotent: caches on the submodule's HEAD SHA + this script's SHA. Re-run
# after `git submodule update` or after editing this script.
#
# Output: $REPO_ROOT/Frameworks/GhosttyKit.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
OUT_DIR="$REPO_ROOT/Frameworks"
XCFRAMEWORK="$OUT_DIR/GhosttyKit.xcframework"
CACHE_FILE="$REPO_ROOT/.build-ghostty.cache"
QUAY_RESOURCES_DIR="$REPO_ROOT/Quay/Resources"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

stage_resources() {
    local share_dir="$GHOSTTY_DIR/zig-out/share"
    local terminfo_dir="$share_dir/terminfo"
    local shell_integration_dir="$share_dir/ghostty/shell-integration"

    [[ -f "$terminfo_dir/78/xterm-ghostty" ]] || \
        fail "missing Ghostty terminfo at $terminfo_dir/78/xterm-ghostty"
    [[ -d "$shell_integration_dir" ]] || \
        fail "missing Ghostty shell integration at $shell_integration_dir"

    bold "==> Staging Ghostty runtime resources -> $QUAY_RESOURCES_DIR"
    mkdir -p "$QUAY_RESOURCES_DIR/ghostty"
    rm -rf "$QUAY_RESOURCES_DIR/terminfo" "$QUAY_RESOURCES_DIR/ghostty/shell-integration"
    cp -R "$terminfo_dir" "$QUAY_RESOURCES_DIR/terminfo"
    cp -R "$shell_integration_dir" "$QUAY_RESOURCES_DIR/ghostty/shell-integration"
}

resources_staged() {
    [[ -f "$QUAY_RESOURCES_DIR/terminfo/78/xterm-ghostty" && \
       -f "$QUAY_RESOURCES_DIR/ghostty/shell-integration/zsh/.zshenv" ]]
}

[[ -d "$GHOSTTY_DIR/.git" || -f "$GHOSTTY_DIR/.git" ]] || \
    fail "vendor/ghostty not initialized. Run: git submodule update --init"

# Pin to Zig 0.15 — Ghostty 1.3.x requires it explicitly (build.zig.zon
# minimum_zig_version=0.15.2). The unversioned `zig` formula tracks 0.16+,
# which fails at compile time, so always prefer the keg-only zig@0.15.
if [[ -d "/opt/homebrew/opt/zig@0.15/bin" ]]; then
    ZIG="/opt/homebrew/opt/zig@0.15/bin/zig"
elif [[ -d "/usr/local/opt/zig@0.15/bin" ]]; then
    ZIG="/usr/local/opt/zig@0.15/bin/zig"
elif command -v zig >/dev/null 2>&1; then
    ZIG="$(command -v zig)"
    actual_ver=$("$ZIG" version)
    case "$actual_ver" in
        0.15.*) : ;;
        *) fail "found zig $actual_ver, but Ghostty needs 0.15.x. Run: brew install zig@0.15" ;;
    esac
else
    fail "zig not found. Run: brew install zig@0.15"
fi

# Cache key: submodule SHA + this script's SHA. If unchanged and the
# xcframework exists, no-op.
ghostty_sha=$(git -C "$GHOSTTY_DIR" rev-parse HEAD)
script_sha=$(shasum "$0" | awk '{print $1}')
cache_key="$ghostty_sha:$script_sha"

if [[ -f "$CACHE_FILE" && -d "$XCFRAMEWORK" ]]; then
    if [[ "$(cat "$CACHE_FILE")" == "$cache_key" ]]; then
        if ! resources_staged; then
            stage_resources
        fi
        bold "==> GhosttyKit.xcframework up to date (cache hit, ghostty=${ghostty_sha:0:8})"
        exit 0
    fi
fi

bold "==> Building libghostty xcframework (zig=$("$ZIG" version), ghostty=${ghostty_sha:0:8})"
echo "    This downloads dependencies on first run and can take 5-10 minutes."

mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK" "$GHOSTTY_DIR/zig-out" "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

# Build options:
#   -Demit-xcframework: produce the macOS xcframework.
#   -Dxcframework-target=native: build for the host arch only. The "universal"
#     option also bundles iOS + iOS-Simulator slices, which we don't need.
#     Intel macOS support is best-effort (PRD §7) — Rosetta covers it.
#   -Drenderer=metal + -Dfont-backend=coretext: macOS-native stack.
#   -Dapp-runtime=none: produce the embeddable library, not the GTK app.
#   Disable everything we don't need so the build stays fast.
( cd "$GHOSTTY_DIR" && "$ZIG" build install \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Drenderer=metal \
    -Dfont-backend=coretext \
    -Dapp-runtime=none \
    -Demit-exe=false \
    -Demit-test-exe=false \
    -Demit-bench=false \
    -Demit-helpgen=false \
    -Demit-docs=false \
    -Demit-terminfo=false \
    -Demit-termcap=false \
    -Demit-themes=false \
    -Demit-macos-app=false )

# Ghostty's XCFrameworkStep writes to a static path relative to the
# zig-build cwd: vendor/ghostty/macos/GhosttyKit.xcframework. The find
# is a safety net for upstream relocations.
SRC="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
if [[ ! -d "$SRC" ]]; then
    SRC=$(find "$GHOSTTY_DIR" -type d -name 'GhosttyKit.xcframework' -not -path '*/Frameworks/*' -print -quit)
fi
[[ -n "${SRC:-}" && -d "$SRC" ]] || fail "build succeeded but no GhosttyKit.xcframework was produced"

bold "==> Staging $SRC -> $XCFRAMEWORK"
cp -R "$SRC" "$XCFRAMEWORK"
stage_resources

echo "$cache_key" > "$CACHE_FILE"
bold "==> Done."
