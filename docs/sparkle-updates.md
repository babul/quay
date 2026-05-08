# Sparkle Auto-Updates

Quay delivers updates via [Sparkle 2](https://sparkle-project.org), hosted on GitHub Pages and GitHub Releases.

```
Quay.app (Sparkle)
    ↓ checks
https://babul.github.io/quay/appcast.xml     (gh-pages branch)
    ↓ download URL inside appcast
https://github.com/babul/quay/releases/download/vX.Y.Z/Quay-X.Y.Z.dmg
    ↓ verified with EdDSA, mounted and installed by Sparkle
```

## One-time setup (do once per developer machine releasing builds)

### 1. Get the Sparkle CLI tools

```sh
./scripts/bootstrap-sparkle.sh
```

Downloads `sign_update`, `generate_keys`, and `generate_appcast` into `vendor/sparkle/bin/` (gitignored). The version in the script matches the SPM dependency in `project.yml` — update `SPARKLE_VERSION` in the script if you bump Sparkle.

### 2. Generate the EdDSA keypair

```sh
./vendor/sparkle/bin/generate_keys
```

This stores the **private key in your macOS login Keychain** under item `https://sparkle-project.org` (account `ed25519`). The public key is printed to stdout.

**Back up the private key now** — if it is lost, existing installs can never verify a future update (they'd need a manual reinstall):

```sh
# Export to a secure location, then delete the file
./vendor/sparkle/bin/generate_keys -x ~/quay-eddsa-private.key
# Store quay-eddsa-private.key in your password manager, then:
rm ~/quay-eddsa-private.key
```

### 3. Add the public key to the project

Paste the printed public key into `project.yml` under `SUPublicEDKey`:

```yaml
SUPublicEDKey: "<paste here>"
```

Then regenerate the Xcode project:

```sh
xcodegen generate
```

### 4. Create the gh-pages branch

```sh
git switch --orphan gh-pages
git commit --allow-empty -m "chore: initialize gh-pages for Sparkle appcast"
git push -u origin gh-pages
git switch main
```

In GitHub repo settings → **Pages** → set source to the `gh-pages` branch, root directory. The feed URL `https://babul.github.io/quay/appcast.xml` must be live before shipping the first build that has Sparkle enabled.

---

## Release flow

```sh
./scripts/release.sh [--dry-run]
```

The script:
1. Reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`.
2. Checks that the version tag doesn't already exist, the tree is clean, and local `main` is in sync with `origin/main`.
3. Prompts for the new version and build number.
4. Opens your `$EDITOR` with a git-log draft — delete the lines you don't want in the release notes.
5. Pipes your curated notes through `claude` (or `codex` if `claude` isn't on PATH) to polish them for end users. The polished result reopens in `$EDITOR` for a final tweak. Override the formatter: `RELEASE_NOTES_FORMATTER=claude|codex|skip`.
6. Commits the polished notes alongside the version bump in `project.yml` and pushes `main`.
7. Calls `scripts/notarize.sh` → produces a notarized, stapled `Quay.app`.
8. Creates a DMG with `hdiutil` → `build/release/Quay-X.Y.Z.dmg` (includes an `/Applications` symlink for drag-to-install).
9. Notarizes and staples the DMG separately (required for Gatekeeper to accept the container).
10. Calls `sign_update` to generate an EdDSA signature over the DMG (reads the private key from your Keychain).
11. Checks out the `gh-pages` branch in a git worktree, prepends a new `<item>` (with inline release notes) to `appcast.xml`, commits, and pushes.
12. Creates a GitHub Release with the DMG attached, tagged `vX.Y.Z`.

**BYO notes**: drop a pre-written `release-notes/vX.Y.Z.md` into the repo before running the script — the editor and polish steps are skipped entirely and your file is used verbatim.

**Dry run**: `./scripts/release.sh --dry-run` stops after committing and pushing the bump, then prints the appcast `<item>` that would be added. Nothing is notarized or published.

GitHub Pages takes 1–2 minutes to deploy after the `gh-pages` push — installed copies of older Quay versions will see the update on their next automatic check.

---

## Appcast format reference

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Quay</title>
        <link>https://github.com/babul/quay</link>
        <description>Quay update feed</description>
        <language>en</language>
        <item>
            <title>Version 0.1.1</title>
            <pubDate>Wed, 07 May 2026 12:00:00 +0000</pubDate>
            <sparkle:version>2</sparkle:version>           <!-- CURRENT_PROJECT_VERSION -->
            <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<style>code{background:rgba(127,127,127,.15);padding:1px 4px;border-radius:3px;}ul,ol{padding-left:1.2em;}</style>
<h2>What's Changed</h2>
<ul>
  <li>Sidebar hides automatically when connected and reappears on hover or ⌘B</li>
</ul>
<p><strong>Full Changelog</strong>: <a href="https://github.com/babul/quay/compare/v0.1.0...v0.1.1">v0.1.0...v0.1.1</a></p>
            ]]></description>
            <enclosure url="https://github.com/babul/quay/releases/download/v0.1.1/Quay-0.1.1.dmg"
                       sparkle:edSignature="<base64>"
                       length="12345678"
                       type="application/x-apple-diskimage" />
        </item>
    </channel>
</rss>
```

`sparkle:version` is the internal build number Sparkle uses for version comparison. `sparkle:shortVersionString` is what users see. Both must be present when they differ.

`<description>` carries release notes as inline HTML inside a CDATA block — Sparkle 2 renders this in its update dialog's WKWebView. It is only shown when `<sparkle:releaseNotesLink>` is absent; since we don't emit that element, the description is always used.

## Where notes live

- **Polished Markdown**: `release-notes/vX.Y.Z.md` on the `main` branch (committed alongside the version bump). Use a prior release's file as a template for BYO-mode releases.
- **Rendered HTML**: embedded inline in each `<item>` on `gh-pages`. No separate hosted file is needed.

---

## Sandboxing note

Quay is **non-sandboxed** (no `.entitlements` file). This is the simplest Sparkle 2 configuration — no XPC mach-lookup entitlements are needed. Sparkle's Installer and Downloader XPC services are still bundled, and Xcode's Archive→Export workflow re-signs them with your Developer ID automatically, preserving Hardened Runtime. The existing `notarize.sh` runs `codesign --verify --deep --strict` which catches any mis-signed nested binaries.

If Quay is ever submitted to the Mac App Store, consult [Sparkle's sandboxing docs](https://sparkle-project.org/documentation/sandboxing) — temporary mach-lookup entitlements will be required.

---

## Recovering from a lost EdDSA private key

If the private key is lost:
1. Generate a new keypair with `./vendor/sparkle/bin/generate_keys`.
2. Update `SUPublicEDKey` in `project.yml` and bump `MARKETING_VERSION`.
3. Ship a transitional release. **Users on older builds will not be able to auto-update** to this release because their app verifies signatures with the old public key. They must download manually from the GitHub Releases page.
4. After the majority of users are on the new key, future releases work normally again.

This is why backing up the private key in a password manager immediately after generating it is essential.
