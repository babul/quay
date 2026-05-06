# Notarization

Quay is distributed outside the Mac App Store and must be notarized for Gatekeeper to allow launch on any Mac. The `scripts/notarize.sh` script archives, exports, notarizes, and staples in one step.

## One-time credential setup

Store your App Store Connect credentials under the profile name `notarytool-quay` (the default the script expects). Choose one auth method:

**API key (recommended)** — generate a key in [App Store Connect → Users → Keys](https://appstoreconnect.apple.com/access/api):
```sh
xcrun notarytool store-credentials notarytool-quay \
  --key /path/to/AuthKey_XXXX.p8 \
  --key-id XXXX \
  --issuer <issuer-uuid>
```

**Apple ID app-specific password** — generate at [appleid.apple.com](https://appleid.apple.com):
```sh
xcrun notarytool store-credentials notarytool-quay \
  --apple-id <email> \
  --team-id T5F5K95U46 \
  --password <app-specific-password>
```

Credentials are stored in your login keychain — never in the repo.

## Building a notarized release

```sh
./scripts/notarize.sh
```

The script:
1. Archives Quay (Release configuration) via `xcodebuild archive`
2. Copies `Quay.app` from the archive and manually re-signs Sparkle's nested XPC services and helper binaries with the Developer ID certificate (per Sparkle's recommended distribution workflow)
3. Verifies the Developer ID + Hardened Runtime signature locally
4. Submits a zip to `notarytool submit --wait`
5. Staples the ticket and validates with `xcrun stapler validate`
6. Confirms `spctl --assess … source=Notarized Developer ID`

Output is at `build/notarize/export/Quay.app`.

**Options:**
- `--profile NAME` — use a different keychain profile (default: `notarytool-quay`)
- `--skip-archive` — skip the archive/export steps and re-run notarization on an existing `build/notarize/export/Quay.app`

## Troubleshooting

**Rejected by Apple** — the script fetches and prints the developer log automatically. To fetch it manually:
```sh
xcrun notarytool log <submission-id> --keychain-profile notarytool-quay
```

**Common rejection reasons:**
- *Hardened Runtime not enabled* — check `ENABLE_HARDENED_RUNTIME: YES` is set in `project.yml` for all targets.
- *Secure timestamp missing* — codesign must use `-o runtime` (hardened runtime implies this; `xcodebuild archive` sets it when `ENABLE_HARDENED_RUNTIME=YES`).
- *Embedded binary not signed / no secure timestamp* — Sparkle's framework ships pre-signed with ad-hoc signatures, which Apple rejects. The script re-signs `Updater.app`, `Autoupdate`, `Installer.xpc`, and `Downloader.xpc` with your Developer ID certificate. If notarization still rejects these, confirm the Developer ID certificate is installed via `security find-identity -v -p codesigning`.

**Signing identity missing** — confirm the Developer ID Application cert is installed:
```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

**Entitlements** — Quay currently has no exception entitlements (no JIT, no library-validation disable). If a future feature requires one, add `Quay/Quay.entitlements` and wire it via `CODE_SIGN_ENTITLEMENTS` in `project.yml`.
