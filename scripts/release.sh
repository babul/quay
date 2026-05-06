#!/usr/bin/env bash
# release.sh — build, notarize, sign for Sparkle, update appcast, and publish a GitHub release.
#
# Usage:
#   ./scripts/release.sh [--notes <file>]
#
# Reads MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml.
# The gh-pages branch must already exist (see docs/sparkle-updates.md for one-time setup).
# The Sparkle EdDSA private key must be in the login Keychain (run scripts/bootstrap-sparkle.sh
# once to download the CLI tools and generate_keys).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "  %s\n" "$*"; }
fail()  { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES_FILE="$2"; shift 2 ;;
    *)        fail "unknown argument: $1" ;;
  esac
done

# ── version from project.yml ──────────────────────────────────────────────────
VERSION="$(grep 'MARKETING_VERSION:' "$REPO_ROOT/project.yml" | head -1 | awk '{print $2}' | tr -d '"')"
BUILD="$(grep 'CURRENT_PROJECT_VERSION:' "$REPO_ROOT/project.yml" | head -1 | awk '{print $2}' | tr -d '"')"
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from project.yml"
[[ -n "$BUILD"   ]] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"
TAG="v${VERSION}"
ZIP_NAME="Quay-${VERSION}.zip"

info "version: $VERSION  build: $BUILD  tag: $TAG"

# ── locate sign_update ─────────────────────────────────────────────────────────
SIGN_UPDATE=""
if [[ -x "$REPO_ROOT/vendor/sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="$REPO_ROOT/vendor/sparkle/bin/sign_update"
elif [[ -x "/Applications/Sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="/Applications/Sparkle/bin/sign_update"
else
  fail "sign_update not found.\n\nRun ./scripts/bootstrap-sparkle.sh to download Sparkle CLI tools,\nor install via: brew install --cask sparkle"
fi

# ── preflight ─────────────────────────────────────────────────────────────────
bold "==> Preflight checks"

command -v gh >/dev/null || fail "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty — commit or stash changes first"

git fetch --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists — bump MARKETING_VERSION in project.yml before releasing"
fi

if ! git rev-parse --verify gh-pages >/dev/null 2>&1 && \
   ! git ls-remote --exit-code origin gh-pages >/dev/null 2>&1; then
  fail "gh-pages branch not found.\n\nSee docs/sparkle-updates.md for one-time setup."
fi

info "preflight OK"

# ── notarize ──────────────────────────────────────────────────────────────────
bold "==> Notarizing"
"$REPO_ROOT/scripts/notarize.sh"

APP="$REPO_ROOT/build/notarize/export/Quay.app"
[[ -d "$APP" ]] || fail "notarize.sh did not produce $APP"

# ── zip for Sparkle ───────────────────────────────────────────────────────────
bold "==> Creating distribution zip"
mkdir -p "$REPO_ROOT/build/release"
ZIP_PATH="$REPO_ROOT/build/release/$ZIP_NAME"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"
info "archive: $ZIP_PATH"

# ── EdDSA signature ───────────────────────────────────────────────────────────
bold "==> Signing with EdDSA"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH")"
ED_SIG="$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)"
ED_LEN="$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)"
[[ -n "$ED_SIG" ]] || fail "sign_update did not produce an EdDSA signature — is the private key in your login Keychain? (run scripts/bootstrap-sparkle.sh)"
[[ -n "$ED_LEN" ]] || fail "sign_update did not produce a length"
info "signature: ${ED_SIG:0:24}…  length: $ED_LEN"

# ── update appcast on gh-pages ────────────────────────────────────────────────
bold "==> Updating appcast.xml on gh-pages"
WORKTREE="$REPO_ROOT/build/gh-pages"
rm -rf "$WORKTREE"
git worktree add "$WORKTREE" gh-pages

APPCAST="$WORKTREE/appcast.xml"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
RELEASE_URL="https://github.com/babul/quay/releases/download/${TAG}/${ZIP_NAME}"

NEW_ITEM="$(cat <<XMLEOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="${RELEASE_URL}"
                       sparkle:edSignature="${ED_SIG}"
                       length="${ED_LEN}"
                       type="application/octet-stream" />
        </item>
XMLEOF
)"

python3 - "$APPCAST" "$NEW_ITEM" <<'PYEOF'
import sys, re

appcast_path = sys.argv[1]
new_item     = sys.argv[2]

HEADER = '''\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Quay</title>
        <link>https://github.com/babul/quay</link>
        <description>Quay update feed</description>
        <language>en</language>'''

FOOTER = '\n    </channel>\n</rss>\n'

try:
    content = open(appcast_path).read()
    existing_items = re.findall(r'<item>.*?</item>', content, re.DOTALL)
except FileNotFoundError:
    existing_items = []

with open(appcast_path, 'w') as f:
    f.write(HEADER + '\n')
    f.write(new_item + '\n')
    for item in existing_items:
        f.write('        ' + item.strip() + '\n')
    f.write(FOOTER)
PYEOF

git -C "$WORKTREE" add appcast.xml
git -C "$WORKTREE" commit -m "release: ${TAG}"
git -C "$WORKTREE" push origin gh-pages
git worktree remove "$WORKTREE"
info "appcast.xml updated on gh-pages"

# ── GitHub release ─────────────────────────────────────────────────────────────
bold "==> Creating GitHub release ${TAG}"

GH_NOTES_FLAG=()
if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || fail "notes file not found: $NOTES_FILE"
  GH_NOTES_FLAG=(--notes-file "$NOTES_FILE")
else
  GH_NOTES_FLAG=(--generate-notes)
fi

gh release create "$TAG" \
  "$ZIP_PATH" \
  --title "Quay ${VERSION}" \
  "${GH_NOTES_FLAG[@]}"

bold "==> Done"
printf "\n  Release:  https://github.com/babul/quay/releases/tag/%s\n" "$TAG"
printf "  Appcast:  https://babul.github.io/quay/appcast.xml\n\n"
printf "  GitHub Pages may take 1–2 minutes to serve the updated appcast.\n\n"
