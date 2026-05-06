#!/usr/bin/env bash
# bootstrap-sparkle.sh — download Sparkle CLI tools into vendor/sparkle/.
#
# Run this once before your first release. The tools (sign_update, generate_keys,
# generate_appcast) end up in vendor/sparkle/bin/ and are gitignored.
#
# The version here should match the Sparkle SPM version in project.yml.
# Update SPARKLE_VERSION if you bump the SPM dependency.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.6.4"
DEST="$REPO_ROOT/vendor/sparkle"
TARBALL="$REPO_ROOT/vendor/sparkle-${SPARKLE_VERSION}.tar.xz"
DOWNLOAD_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "  %s\n" "$*"; }
fail() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

if [[ -x "$DEST/bin/sign_update" ]]; then
  info "Sparkle CLI tools already present at vendor/sparkle/ — nothing to do."
  exit 0
fi

bold "==> Downloading Sparkle ${SPARKLE_VERSION}"
command -v curl >/dev/null || fail "curl not found"
curl -L --progress-bar -o "$TARBALL" "$DOWNLOAD_URL"

bold "==> Extracting to vendor/sparkle/"
mkdir -p "$DEST"
tar -xJf "$TARBALL" -C "$DEST" bin/sign_update bin/generate_keys bin/generate_appcast 2>/dev/null || \
  tar -xJf "$TARBALL" -C "$DEST"
rm -f "$TARBALL"

[[ -x "$DEST/bin/sign_update" ]] || fail "sign_update not found after extraction — check the tarball structure"
info "sign_update:    $DEST/bin/sign_update"
info "generate_keys:  $DEST/bin/generate_keys"
bold "==> Done"

printf "\nTo generate your EdDSA keypair (one-time, stores private key in login Keychain):\n"
printf "  %s/bin/generate_keys\n\n" "$DEST"
printf "Copy the printed public key into project.yml → SUPublicEDKey and regenerate:\n"
printf "  xcodegen generate\n\n"
