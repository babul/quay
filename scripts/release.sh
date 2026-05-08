#!/usr/bin/env bash
# release.sh — build, notarize, sign for Sparkle, update appcast, and publish a GitHub release.
#
# Usage:
#   ./scripts/release.sh [--dry-run]
#
# Prompts for version/build, opens $EDITOR with a git-log draft for curation,
# polishes the notes via claude (or codex), commits project.yml + release-notes/
# to main, pushes, then notarizes, signs, updates the appcast, and creates a
# GitHub release. Pass --dry-run to stop after the push and print the appcast item.
#
# Override the LLM formatter: RELEASE_NOTES_FORMATTER=claude|codex|skip
# BYO notes: drop release-notes/vX.Y.Z.md before running to skip editor+polish.
#
# The gh-pages branch must exist (see docs/sparkle-updates.md).
# The Sparkle EdDSA private key must be in the login Keychain.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── arg parse ─────────────────────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) printf 'usage: %s [--dry-run]\n' "$(basename "${BASH_SOURCE[0]}")"; exit 0 ;;
    *) printf '\033[31merror:\033[0m unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

bold()          { printf "\033[1m%s\033[0m\n" "$*"; }
info()          { printf "  %s\n" "$*"; }
fail()          { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }
json_get()      { printf '%s' "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get(sys.argv[1],''))" "$2"; }
# Extract the value of attr="…" from stdin (first match).
extract_attr()  { grep -o "$1=\"[^\"]*\"" | head -1 | cut -d'"' -f2; }
require_nonempty() { [[ -s "$1" ]] || fail "$2"; }

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

# Inline <style> shipped inside every appcast <description> CDATA block.
APPCAST_DESC_STYLE='<style>code{background:rgba(127,127,127,.15);padding:1px 4px;border-radius:3px;}ul,ol{padding-left:1.2em;}</style>'

# Read the macOS deployment target from project.yml (e.g. "15.0").
read_macos_deployment_target() {
  awk '/^[[:space:]]*macOS:/ { gsub(/"/,""); print $2; exit }' "$REPO_ROOT/project.yml"
}

# Render an appcast <item>. Args: version build pubdate enclosure-url ed-sig ed-len html-body
render_appcast_item() {
  local version="$1" build="$2" pub_date="$3" enclosure_url="$4" ed_sig="$5" ed_len="$6" html_body="$7"
  local min_macos
  min_macos="$(read_macos_deployment_target)"
  cat <<XMLEOF
        <item>
            <title>Version ${version}</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:version>${build}</sparkle:version>
            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${min_macos}</sparkle:minimumSystemVersion>
            <description><![CDATA[${APPCAST_DESC_STYLE}
${html_body}
            ]]></description>
            <enclosure url="${enclosure_url}"
                       sparkle:edSignature="${ed_sig}"
                       length="${ed_len}"
                       type="application/x-apple-diskimage" />
        </item>
XMLEOF
}

# Pipe stdin through the chosen LLM formatter; instruction is argv (no quoting hazard with markdown body)
format_with_llm() {
  local tool="$1"
  local instruction
  instruction='You are formatting release notes for Quay, a native macOS SSH connection manager.

Rewrite the bullet entries on stdin (kept by the developer from a raw git log) as concise, user-facing release notes in clean Markdown.

Rules:
- Drop conventional-commit prefixes like "feat(tabs):", "fix:", "chore(release):", "refactor:".
- Drop short commit hashes (e.g. "3c6e8c7") at the start of bullets.
- Phrase bullets so an end user understands the impact, not the implementation.
- Group under "## New", "## Improvements", "## Fixes" only if items naturally split. If everything fits one short list, keep it flat.
- Use "-" (hyphen) for every bullet — never "*" or "1." — and never nest lists.
- Tighten language. One bullet per change. No marketing fluff.
- Preserve any "## What'\''s Changed" header at the top and any "**Full Changelog**" link at the bottom verbatim.
- Output ONLY the polished markdown — no preamble, no code fences, no commentary.'
  case "$tool" in
    claude) claude -p "$instruction" ;;
    codex)  codex exec "$instruction" ;;
    *)      cat ;;
  esac
}

# Resolve the formatter to use, honouring $RELEASE_NOTES_FORMATTER and falling back
# to whatever LLM CLI is on PATH. Echoes the chosen formatter (or "skip").
# Arg: $1 = informational note printed when no formatter is available.
select_formatter() {
  local none_msg="${1:-no formatter on PATH — skipping polish}"
  local formatter="${RELEASE_NOTES_FORMATTER:-claude}"
  if [[ "$formatter" == "skip" ]] || command -v "$formatter" >/dev/null; then
    printf '%s' "$formatter"
    return
  fi
  local requested="$formatter" candidate
  for candidate in claude codex; do
    if [[ "$candidate" != "$requested" ]] && command -v "$candidate" >/dev/null; then
      info "$requested not found — falling back to $candidate" >&2
      printf '%s' "$candidate"
      return
    fi
  done
  info "$none_msg" >&2
  printf 'skip'
}

# Run format_with_llm in the background with a periodic "skip?" prompt.
# Args: $1 = formatter, $2 = input file, $3 = output file
# Echoes "skipped" if the user chose to skip, "ok" otherwise.
run_llm_with_skip_prompt() {
  local formatter="$1" input="$2" output="$3"
  ( format_with_llm "$formatter" < "$input" > "$output" ) &
  local pid=$! ans
  local next_prompt_at=$(( SECONDS + 60 ))
  while kill -0 "$pid" 2>/dev/null; do
    sleep 3
    printf '.' >&2
    if (( SECONDS >= next_prompt_at )); then
      printf '\n' >&2
      if read -r -t 10 -p "  → still running after $((SECONDS - next_prompt_at + 60))s. skip? [y/N] " ans \
         && [[ "$ans" =~ ^[Yy] ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        printf '\n' >&2
        printf 'skipped'
        return
      fi
      next_prompt_at=$(( SECONDS + 60 ))
    fi
  done
  wait "$pid" 2>/dev/null || true
  printf '\n' >&2
  printf 'ok'
}

# Load shared markdown-to-HTML converter
source "$(dirname "${BASH_SOURCE[0]}")/lib-md-to-html.sh"

# Library mode: source for helpers only (used by backfill-release-notes.sh).
[[ "${RELEASE_SH_LIB_ONLY:-0}" == "1" ]] && return 0

# ── locate sign_update ────────────────────────────────────────────────────────
SIGN_UPDATE=""
if [[ -x "$REPO_ROOT/vendor/sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="$REPO_ROOT/vendor/sparkle/bin/sign_update"
elif [[ -x "/Applications/Sparkle/bin/sign_update" ]]; then
  SIGN_UPDATE="/Applications/Sparkle/bin/sign_update"
else
  fail "sign_update not found.\n\nRun ./scripts/bootstrap-sparkle.sh to download Sparkle CLI tools,\nor install via: brew install --cask sparkle"
fi

NOTARIZE_PROFILE="notarytool-quay"  # must match the profile used in notarize.sh

# ── early preflight (before any prompts) ─────────────────────────────────────
bold "==> Preflight checks"

command -v gh >/dev/null || fail "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty — commit or stash changes first"

if ! git rev-parse --verify gh-pages >/dev/null 2>&1 && \
   ! git ls-remote --exit-code origin gh-pages >/dev/null 2>&1; then
  fail "gh-pages branch not found.\n\nSee docs/sparkle-updates.md for one-time setup."
fi

git fetch --quiet origin main
LOCAL_MAIN="$(git rev-parse main)"
REMOTE_MAIN="$(git rev-parse origin/main)"
if [[ "$LOCAL_MAIN" != "$REMOTE_MAIN" ]] && \
   [[ "$(git merge-base origin/main main)" != "$REMOTE_MAIN" ]]; then
  fail "local main is behind or diverged from origin/main — pull/rebase first"
fi

info "preflight OK"

# ── version prompt ────────────────────────────────────────────────────────────
CURRENT_VERSION="$(read_yml_key 'MARKETING_VERSION')"
CURRENT_BUILD="$(read_yml_key 'CURRENT_PROJECT_VERSION')"
[[ -n "$CURRENT_VERSION" ]] || fail "could not read MARKETING_VERSION from project.yml"
[[ -n "$CURRENT_BUILD"   ]] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"

# Compute the highest sparkle:version already published to enforce monotonic build numbers.
MAX_PUBLISHED_BUILD="$(git show gh-pages:appcast.xml 2>/dev/null \
  | grep -oE '<sparkle:version>[0-9]+</sparkle:version>' \
  | grep -oE '[0-9]+' \
  | sort -rn | head -1)"
MAX_PUBLISHED_BUILD="${MAX_PUBLISHED_BUILD:-0}"
NEXT_BUILD="$((MAX_PUBLISHED_BUILD + 1))"

printf "\n"
read -r -p "  Version [$CURRENT_VERSION]: " INPUT_VERSION
read -r -p "  Build   [$NEXT_BUILD]: "       INPUT_BUILD
printf "\n"

VERSION="${INPUT_VERSION:-$CURRENT_VERSION}"
BUILD="${INPUT_BUILD:-$NEXT_BUILD}"

# Enforce strictly monotonic build numbers across releases.
if (( BUILD <= MAX_PUBLISHED_BUILD )); then
  fail "build number $BUILD must be > highest published ($MAX_PUBLISHED_BUILD)"
fi
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

command -v xcodegen >/dev/null || fail "xcodegen not found — run: brew install xcodegen"
xcodegen generate --quiet

info "version: $VERSION  build: $BUILD  tag: $TAG"

# ── release notes ─────────────────────────────────────────────────────────────
bold "==> Preparing release notes"

mkdir -p "$REPO_ROOT/build/release"
NOTES_TMP="$REPO_ROOT/build/release-notes-${TAG}.md"
COMMITTED_NOTES="$REPO_ROOT/release-notes/${TAG}.md"

if [[ -f "$COMMITTED_NOTES" ]]; then
  cp "$COMMITTED_NOTES" "$NOTES_TMP"
  info "using pre-staged $COMMITTED_NOTES verbatim — skipping editor/polish"
else
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  {
    printf "## What's Changed\n\n"
    if [[ -n "$LAST_TAG" ]]; then
      git log --oneline "${LAST_TAG}..HEAD" --no-decorate | sed 's/^/- /'
      printf "\n**Full Changelog**: https://github.com/babul/quay/compare/%s...%s\n" "$LAST_TAG" "$TAG"
    else
      git log --oneline --no-decorate | sed 's/^/- /'
    fi
  } > "$NOTES_TMP"

  EDITOR="${EDITOR:-$(command -v nano || command -v vi)}"
  "$EDITOR" "$NOTES_TMP"
  require_nonempty "$NOTES_TMP" "release notes are empty — aborting"

  # ── polish with LLM ─────────────────────────────────────────────────────────
  bold "==> Polishing release notes"

  FORMATTER="$(select_formatter "no formatter on PATH — skipping polish")"

  if [[ "$FORMATTER" != "skip" ]]; then
    POLISHED_TMP="$(mktemp)"
    info "running $FORMATTER (will prompt to skip after 60s)"
    LLM_RESULT="$(run_llm_with_skip_prompt "$FORMATTER" "$NOTES_TMP" "$POLISHED_TMP")"

    if [[ "$LLM_RESULT" == "ok" ]] && [[ -s "$POLISHED_TMP" ]]; then
      cp "$POLISHED_TMP" "$NOTES_TMP"
      info "polished — opening editor for final review"
      "$EDITOR" "$NOTES_TMP"
      require_nonempty "$NOTES_TMP" "release notes are empty after review"
    else
      info "keeping original notes (formatter skipped or empty output)"
    fi
    rm -f "$POLISHED_TMP"
  fi
fi

# ── markdown → html (inline <description> for appcast) ────────────────────────
NOTES_HTML_PATH="$REPO_ROOT/build/release-notes-${TAG}.html"
NOTES_HTML_BODY="$(md_to_html "$NOTES_TMP")"
NOTES_HTML_BODY="${NOTES_HTML_BODY//]]>/]]&gt;}"
printf '%s\n' "$NOTES_HTML_BODY" > "$NOTES_HTML_PATH"
info "html: $NOTES_HTML_PATH"

# ── persist polished notes + commit + push ────────────────────────────────────
mkdir -p "$REPO_ROOT/release-notes"
cp "$NOTES_TMP" "$COMMITTED_NOTES"
info "saved $COMMITTED_NOTES"

if [[ "$CHANGED_YML" -eq 1 ]]; then
  git add project.yml "$COMMITTED_NOTES"
  git commit -m "chore(release): bump to ${TAG}"
  info "committed version bump + notes → ${TAG}"
elif [[ -n "$(git status --porcelain "$COMMITTED_NOTES")" ]]; then
  git add "$COMMITTED_NOTES"
  git commit -m "chore(release): notes for ${TAG}"
  info "committed release notes for ${TAG}"
fi

git push origin main
info "pushed main"

if (( DRY_RUN == 1 )); then
  bold "==> --dry-run: stopping before notarize"
  info "appcast item that would be added:"
  render_appcast_item \
    "$VERSION" "$BUILD" \
    "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
    "https://github.com/babul/quay/releases/download/${TAG}/Quay-${VERSION}.dmg" \
    "DRY_RUN_PLACEHOLDER" "DRY_RUN_PLACEHOLDER" \
    "$NOTES_HTML_BODY"
  exit 0
fi

# ── notarize ──────────────────────────────────────────────────────────────────
bold "==> Notarizing"
"$REPO_ROOT/scripts/notarize.sh"

APP="$REPO_ROOT/build/notarize/export/Quay.app"
[[ -d "$APP" ]] || fail "notarize.sh did not produce $APP"

# ── DMG for Sparkle ───────────────────────────────────────────────────────────
DMG_NAME="Quay-${VERSION}.dmg"
bold "==> Creating distribution DMG"
DMG_PATH="$REPO_ROOT/build/release/$DMG_NAME"
rm -f "$DMG_PATH"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -fs HFS+ -volname "Quay" -srcfolder "$STAGING" -ov -format UDZO -o "$DMG_PATH" >/dev/null
rm -rf "$STAGING"
info "image: $DMG_PATH"

# ── notarize + staple DMG ─────────────────────────────────────────────────────
bold "==> Notarizing DMG"
DMG_NOTARY_OUTPUT="$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARIZE_PROFILE" \
  --wait \
  --output-format json)"

DMG_NOTARY_STATUS="$(json_get "$DMG_NOTARY_OUTPUT" status)"
DMG_NOTARY_ID="$(json_get "$DMG_NOTARY_OUTPUT" id)"

if [[ "$DMG_NOTARY_STATUS" != "Accepted" ]]; then
  printf "\033[31mDMG notarization rejected (status: %s, id: %s)\033[0m\n" \
    "$DMG_NOTARY_STATUS" "$DMG_NOTARY_ID" >&2
  [[ -n "$DMG_NOTARY_ID" ]] && \
    xcrun notarytool log "$DMG_NOTARY_ID" --keychain-profile "$NOTARIZE_PROFILE" >&2 || true
  exit 1
fi

info "DMG notarized (id: $DMG_NOTARY_ID)"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
info "DMG stapled"

# ── EdDSA signature ───────────────────────────────────────────────────────────
bold "==> Signing with EdDSA"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
ED_SIG="$(echo "$SIGN_OUTPUT" | extract_attr "sparkle:edSignature")"
ED_LEN="$(echo "$SIGN_OUTPUT" | extract_attr "length")"

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
RELEASE_URL="https://github.com/babul/quay/releases/download/${TAG}/${DMG_NAME}"

NEW_ITEM="$(render_appcast_item "$VERSION" "$BUILD" "$PUB_DATE" "$RELEASE_URL" "$ED_SIG" "$ED_LEN" "$NOTES_HTML_BODY")"

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
  "$DMG_PATH" \
  --title "Quay ${VERSION}" \
  --notes-file "$NOTES_TMP" \
  --target "$(git rev-parse main)"
rm -f "$NOTES_TMP" "$NOTES_HTML_PATH"

bold "==> Done"
printf "\n  Release:  https://github.com/babul/quay/releases/tag/%s\n" "$TAG"
printf "  Appcast:  https://babul.github.io/quay/appcast.xml\n\n"
printf "  GitHub Pages may take 1–2 minutes to serve the updated appcast.\n\n"
