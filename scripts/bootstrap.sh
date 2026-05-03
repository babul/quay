#!/usr/bin/env bash
# bootstrap.sh — first-time setup for Quay.
#
# Verifies toolchain, builds libghostty into Frameworks/GhosttyKit.xcframework,
# generates Quay.xcodeproj from project.yml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

bold "==> Checking toolchain"

command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode 16+."
command -v xcodegen   >/dev/null || fail "xcodegen not found. Run: brew install xcodegen"
command -v zig        >/dev/null || fail "zig not found. Run: brew install zig"

xcode_ver=$(xcodebuild -version | head -1 | awk '{print $2}')
zig_ver=$(zig version)
xg_ver=$(xcodegen --version | awk '{print $2}')
echo "  xcodebuild: $xcode_ver"
echo "  zig:        $zig_ver"
echo "  xcodegen:   $xg_ver"

bold "==> Initializing submodules"
git submodule update --init --recursive

bold "==> Building libghostty (this can take several minutes the first time)"
"$REPO_ROOT/scripts/build-ghostty.sh"

bold "==> Generating Quay.xcodeproj"
xcodegen generate

bold "==> Done."
echo
echo "Open the project:"
echo "  open Quay.xcodeproj"
