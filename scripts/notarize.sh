#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }
json_get() { printf '%s' "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))"; }

# ── args ──────────────────────────────────────────────────────────────────────
PROFILE="notarytool-quay"
SKIP_ARCHIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="$2"; shift 2 ;;
    --skip-archive) SKIP_ARCHIVE=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

ARCHIVE="$REPO_ROOT/build/notarize/Quay.xcarchive"
EXPORT_DIR="$REPO_ROOT/build/notarize/export"
APP="$EXPORT_DIR/Quay.app"
ZIP="$REPO_ROOT/build/notarize/Quay.zip"

# ── preflight ─────────────────────────────────────────────────────────────────
bold "==> Preflight checks"

for cmd in xcodebuild xcrun ditto codesign spctl security; do
  command -v "$cmd" >/dev/null || fail "required command not found: $cmd"
done

if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application: .* (T5F5K95U46)"; then
  fail "Developer ID Application certificate for T5F5K95U46 not found in keychain"
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  fail "notarytool profile \"$PROFILE\" not configured.\n\n  Run one of:\n\n  # API key (recommended)\n  xcrun notarytool store-credentials $PROFILE \\\\\n    --key /path/to/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>\n\n  # Apple ID\n  xcrun notarytool store-credentials $PROFILE \\\\\n    --apple-id <email> --team-id T5F5K95U46 --password <app-specific-password>"
fi

mkdir -p "$REPO_ROOT/build/notarize"

# ── archive + export ──────────────────────────────────────────────────────────
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
  bold "==> Archiving (Release)"
  xcodebuild \
    -project "$REPO_ROOT/Quay.xcodeproj" \
    -scheme Quay \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive

  bold "==> Copying .app from archive"
  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE/Products/Applications/Quay.app" "$EXPORT_DIR/"

  bold "==> Re-signing Sparkle nested code with Developer ID"
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

  # Re-sign Sparkle components with Developer ID certificate
  if [[ -d "$SPARKLE/Versions/B" ]]; then
    local base="$SPARKLE/Versions/B"
    # XPC services and helpers to re-sign
    local -a binaries=(
      "$base/XPCServices/Installer.xpc"
      "$base/XPCServices/Downloader.xpc"
      "$base/Autoupdate"
      "$base/Updater.app"
    )

    for binary in "${binaries[@]}"; do
      if [[ -e "$binary" ]]; then
        codesign -f -s "$DEV_ID_HASH" -o runtime "$binary"
      fi
    done

    # Re-sign framework root (should preserve entitlements from Downloader.xpc)
    codesign -f -s "$DEV_ID_HASH" -o runtime "$SPARKLE"
  fi

  # Re-sign main app bundle
  codesign -f -s "$DEV_ID_HASH" -o runtime \
    --preserve-metadata=entitlements "$APP"
else
  bold "==> Skipping archive (--skip-archive)"
  [[ -d "$APP" ]] || fail "export not found at $APP; run without --skip-archive first"
fi

# ── verify signature ──────────────────────────────────────────────────────────
bold "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
printf '%s' "$SIGN_INFO" | grep -q "flags=.*runtime" || fail "hardened runtime flag not set on $APP"
printf "signature OK\n"

# ── zip + submit ──────────────────────────────────────────────────────────────
bold "==> Creating submission zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

bold "==> Submitting to Apple notarization service"
NOTARY_OUTPUT="$(xcrun notarytool submit "$ZIP" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json)"

NOTARY_STATUS="$(json_get "$NOTARY_OUTPUT" status)"
NOTARY_ID="$(json_get "$NOTARY_OUTPUT" id)"

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  printf "\033[31mNotarization rejected (status: %s, id: %s)\033[0m\n" \
    "$NOTARY_STATUS" "$NOTARY_ID" >&2
  if [[ -n "$NOTARY_ID" ]]; then
    bold "==> Developer log"
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  exit 1
fi

printf "notarization accepted (id: %s)\n" "$NOTARY_ID"
rm -f "$ZIP"

# ── staple ────────────────────────────────────────────────────────────────────
bold "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ── final gatekeeper check ────────────────────────────────────────────────────
bold "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

bold "==> Done"
printf "notarized app: %s\n" "$APP"
