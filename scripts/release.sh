#!/usr/bin/env bash
# release.sh — build, notarize, sign for Sparkle, update appcast, and publish a GitHub release.
#
# Usage:
#   ./scripts/release.sh
#
# Prompts for version, build number, and release notes (opens $EDITOR with a
# draft generated from git log). Updates project.yml and commits the bump before
# archiving. The gh-pages branch must exist (see docs/sparkle-updates.md).
# The Sparkle EdDSA private key must be in the login Keychain.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold()         { printf "\033[1m%s\033[0m\n" "$*"; }
info()         { printf "  %s\n" "$*"; }
fail()         { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

# Read key from project.yml
read_yml_key() {
  local key="$1"
  grep "$key:" "$REPO_ROOT/project.yml" | head -1 | awk '{print $2}' | tr -d '"'
}

# Update key in project.yml
update_yml_key() {
  local key="$1" old_val="$2" new_val="$3"
  sed -i '' "s/${key}: \"${old_val}\"/${key}: \"${new_val}\"/" "$REPO_ROOT/project.yml"
}

# ── locate sign_update ────────────────────────────────────────────────────────
SIGN_UPDATE=""
if [[ -x "$REPO_ROOT/vendor/sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="$REPO_ROOT/vendor/sparkle/bin/sign_update"
elif [[ -x "/Applications/Sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="/Applications/Sparkle/bin/sign_update"
else
  fail "sign_update not found.\n\nRun ./scripts/bootstrap-sparkle.sh to download Sparkle CLI tools,\nor install via: brew install --cask sparkle"
fi

# ── early preflight (before any prompts) ─────────────────────────────────────
bold "==> Preflight checks"

command -v gh >/dev/null || fail "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty — commit or stash changes first"

if ! git rev-parse --verify gh-pages >/dev/null 2>&1 && \
   ! git ls-remote --exit-code origin gh-pages >/dev/null 2>&1; then
  fail "gh-pages branch not found.\n\nSee docs/sparkle-updates.md for one-time setup."
fi

info "preflight OK"

# ── version prompt ────────────────────────────────────────────────────────────
CURRENT_VERSION="$(read_yml_key 'MARKETING_VERSION')"
CURRENT_BUILD="$(read_yml_key 'CURRENT_PROJECT_VERSION')"
[[ -n "$CURRENT_VERSION" ]] || fail "could not read MARKETING_VERSION from project.yml"
[[ -n "$CURRENT_BUILD"   ]] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"

printf "\n"
read -r -p "  Version [$CURRENT_VERSION]: " INPUT_VERSION
read -r -p "  Build   [$CURRENT_BUILD]: "   INPUT_BUILD
printf "\n"

VERSION="${INPUT_VERSION:-$CURRENT_VERSION}"
BUILD="${INPUT_BUILD:-$CURRENT_BUILD}"
TAG="v${VERSION}"

git fetch --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists — enter a different version"
fi

CHANGED_YML=0
if [[ "$VERSION" != "$CURRENT_VERSION" ]]; then
  update_yml_key "MARKETING_VERSION" "$CURRENT_VERSION" "$VERSION"
  CHANGED_YML=1
fi
if [[ "$BUILD" != "$CURRENT_BUILD" ]]; then
  update_yml_key "CURRENT_PROJECT_VERSION" "$CURRENT_BUILD" "$BUILD"
  CHANGED_YML=1
fi

if [[ "$CHANGED_YML" -eq 1 ]]; then
  git add project.yml
  git commit -m "chore(release): bump to ${TAG}"
  info "committed version bump → ${TAG}"
fi

info "version: $VERSION  build: $BUILD  tag: $TAG"

# ── release notes ─────────────────────────────────────────────────────────────
bold "==> Drafting release notes"

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
mkdir -p "$REPO_ROOT/build/release"
NOTES_TMP="$REPO_ROOT/build/release-notes-${TAG}.md"

{
  printf "## What's Changed\n\n"
  if [[ -n "$LAST_TAG" ]]; then
    git log --oneline "${LAST_TAG}..HEAD" --no-decorate \
      | sed 's/^/- /'
    printf "\n**Full Changelog**: https://github.com/babul/quay/compare/%s...%s\n" "$LAST_TAG" "$TAG"
  else
    git log --oneline --no-decorate | sed 's/^/- /'
  fi
} > "$NOTES_TMP"

EDITOR="${EDITOR:-$(command -v nano || command -v vi)}"
"$EDITOR" "$NOTES_TMP"

[[ -s "$NOTES_TMP" ]] || fail "release notes are empty — aborting"

info "release notes saved"

# ── notarize ──────────────────────────────────────────────────────────────────
bold "==> Notarizing"
"$REPO_ROOT/scripts/notarize.sh"

APP="$REPO_ROOT/build/notarize/export/Quay.app"
[[ -d "$APP" ]] || fail "notarize.sh did not produce $APP"

# ── zip for Sparkle ───────────────────────────────────────────────────────────
ZIP_NAME="Quay-${VERSION}.zip"
bold "==> Creating distribution zip"
ZIP_PATH="$REPO_ROOT/build/release/$ZIP_NAME"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"
info "archive: $ZIP_PATH"

# ── EdDSA signature ───────────────────────────────────────────────────────────
bold "==> Signing with EdDSA"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH")"
ED_SIG="$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)"
ED_LEN="$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)"
[[ -n "$ED_SIG" ]] || fail "sign_update produced no EdDSA signature — is the private key in your login Keychain?"
[[ -n "$ED_LEN" ]] || fail "sign_update produced no length"
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

# ── GitHub release ────────────────────────────────────────────────────────────
bold "==> Creating GitHub release ${TAG}"
gh release create "$TAG" \
  "$ZIP_PATH" \
  --title "Quay ${VERSION}" \
  --notes-file "$NOTES_TMP"
rm -f "$NOTES_TMP"

bold "==> Done"
printf "\n  Release:  https://github.com/babul/quay/releases/tag/%s\n" "$TAG"
printf "  Appcast:  https://babul.github.io/quay/appcast.xml\n\n"
printf "  GitHub Pages may take 1–2 minutes to serve the updated appcast.\n\n"
