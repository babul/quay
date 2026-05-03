#!/usr/bin/env bash
# build-ghostty.sh — build libghostty from the vendored submodule and wrap as
# Frameworks/GhosttyKit.xcframework.
#
# Idempotent: caches on the submodule's HEAD SHA + this script's own SHA.
# Re-run after `git submodule update` or after editing this script.
#
# Output: $REPO_ROOT/Frameworks/GhosttyKit.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
OUT_DIR="$REPO_ROOT/Frameworks"
XCFRAMEWORK="$OUT_DIR/GhosttyKit.xcframework"
CACHE_FILE="$REPO_ROOT/.build-ghostty.cache"
BUILD_DIR="$REPO_ROOT/build/ghostty"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

[[ -d "$GHOSTTY_DIR" ]] || fail "vendor/ghostty not found. Run: git submodule update --init"
command -v zig >/dev/null || fail "zig not in PATH. Run: brew install zig"

# Cache key: ghostty submodule SHA + this script's SHA. If unchanged, skip build.
ghostty_sha=$(git -C "$GHOSTTY_DIR" rev-parse HEAD)
script_sha=$(shasum "$0" | awk '{print $1}')
cache_key="$ghostty_sha:$script_sha"

if [[ -f "$CACHE_FILE" && -d "$XCFRAMEWORK" ]]; then
    if [[ "$(cat "$CACHE_FILE")" == "$cache_key" ]]; then
        bold "==> GhosttyKit.xcframework up to date (cache hit, ghostty=${ghostty_sha:0:8})"
        exit 0
    fi
fi

bold "==> Building libghostty (ghostty=${ghostty_sha:0:8})"

mkdir -p "$BUILD_DIR" "$OUT_DIR"
rm -rf "$XCFRAMEWORK"

# Build per-arch static libs. Ghostty's build.zig exposes a `libghostty` step
# (or `libghostty-static`). The exact step name evolves with the ghostty repo;
# inspect `cd vendor/ghostty && zig build --help` if this fails.
ARCHS=(aarch64 x86_64)
LIBS=()
for arch in "${ARCHS[@]}"; do
    target="${arch}-macos"
    bold "  --> $target"
    (
        cd "$GHOSTTY_DIR"
        zig build \
            -Doptimize=ReleaseFast \
            -Dtarget="$target" \
            -Demit-docs=false \
            libghostty
    )
    out_lib="$GHOSTTY_DIR/zig-out/lib/libghostty.a"
    [[ -f "$out_lib" ]] || fail "expected $out_lib after zig build"

    arch_dir="$BUILD_DIR/$arch"
    mkdir -p "$arch_dir/Headers"
    cp "$out_lib" "$arch_dir/libghostty.a"
    cp -R "$GHOSTTY_DIR/include/." "$arch_dir/Headers/"
    LIBS+=("$arch_dir/libghostty.a")
done

# Lipo the slices for the universal arm64+x86_64 macOS slice of the xcframework.
UNIVERSAL_LIB="$BUILD_DIR/macos-universal/libghostty.a"
mkdir -p "$(dirname "$UNIVERSAL_LIB")"
lipo -create "${LIBS[@]}" -output "$UNIVERSAL_LIB"
mkdir -p "$BUILD_DIR/macos-universal/Headers"
cp -R "$GHOSTTY_DIR/include/." "$BUILD_DIR/macos-universal/Headers/"

bold "==> Wrapping as xcframework"
xcodebuild -create-xcframework \
    -library "$UNIVERSAL_LIB" \
    -headers "$BUILD_DIR/macos-universal/Headers" \
    -output "$XCFRAMEWORK"

# Drop a module map so Swift can `import GhosttyKit` (instead of bridging header).
# The bridging header path remains as a fallback for incremental adoption.
MODMAP_DIR="$XCFRAMEWORK/macos-arm64_x86_64/Headers"
cat > "$MODMAP_DIR/module.modulemap" <<'EOF'
module GhosttyKit {
    umbrella header "ghostty.h"
    export *
    module * { export * }
}
EOF

echo "$cache_key" > "$CACHE_FILE"
bold "==> Built $XCFRAMEWORK"
