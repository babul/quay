# Supacode Independence Audit

Date: 2026-05-06

This note records the post-rewrite audit of Quay's libghostty integration against the previously reviewed supacode reference checkout at `../supacode-reference`.

This is an engineering audit note, not legal advice. The review intentionally treats uncertainty as risk.

## Reference Handling

- The supacode repository was cloned as a sibling checkout for read-only comparison.
- No files were copied from the reference checkout into Quay.
- The clean-room rewrites were completed without reading the supacode reference during implementation.
- The reference was reopened only after the rewrite to verify that the old fingerprints were removed and to re-check the previously unclear Quay files.

## Files Rewritten

These files were previously classified as high risk and `NEEDS_REWRITE`; each has been rewritten from Quay's own required behavior:

| File | Lines | Post-rewrite category | Post-rewrite verdict |
| --- | ---: | --- | --- |
| `Quay/Terminal/GhosttyRuntime.swift` | 289 | libghostty runtime and C callbacks | INDEPENDENT |
| `Quay/Terminal/GhosttySurfaceBridge.swift` | 251 | Ghostty action bridge and host side effects | INDEPENDENT |
| `Quay/Terminal/GhosttySurfaceView+IME.swift` | 287 | keyboard input and IME integration | INDEPENDENT |
| `Quay/Terminal/NSEvent+Ghostty.swift` | 111 | AppKit key event translation | INDEPENDENT |

## Post-Rewrite Findings

### `GhosttyRuntime.swift`

Closest supacode analog: `supacode/Infrastructure/Ghostty/GhosttyRuntime.swift`

Structural similarity: low

- Quay now organizes runtime setup around a singleton `GhosttyRuntime.shared`, weak registered bridges, and small static callback helpers.
- Callback handling is grouped by Quay's needs: app actions, clipboard, wakeup, close surface, and bridge lookup.
- Swift 6 strict concurrency boundaries are explicit: C callback raw pointers are converted to integer addresses before entering `MainActor.assumeIsolated`.

Comment fingerprinting: clean

- No matching comments were found against the supacode Ghostty runtime/view files.

Idiosyncratic choices:

- `NSHashTable<GhosttySurfaceBridge>.weakObjects()` for live surface tracking: justified by Quay's bridge-owned view lifecycle.
- Integer-address conversion before main-actor pointer recovery: justified by Swift 6 strict concurrency.
- Selection clipboard support remains disabled: inherited Quay behavior; acceptable but worth noting as a deliberate product choice.

Shape similarity: low

- Supacode has a broader runtime surface for its terminal workspace model; Quay's file is narrower and centered on one app runtime plus registered bridge refresh.

Verdict: INDEPENDENT

### `GhosttySurfaceBridge.swift`

Closest supacode analog: `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift`

Structural similarity: low

- Quay now routes actions through outcome-oriented methods: terminal identity, pointer state, session state, visual state, and host side effects.
- Supacode's bridge is broader: split actions, tab actions, command palette integration, open URL handling, command completion, and search/scroll state.
- Shared names such as `GhosttySurfaceBridge`, `sendText`, and `onTitleChange` are domain-conventional for this integration layer.

Comment fingerprinting: clean

- No copied comments were found.

Idiosyncratic choices:

- Quay posts desktop notifications directly from the bridge: justified by Quay's simpler app model.
- `visibleText()` reads viewport text for login script matching: original Quay behavior not present as a comparable supacode bridge feature.
- Mouse cursor mapping remains a direct enum-to-`NSCursor` mapping: required shape is dictated by libghostty/AppKit, but Quay's map and fallback shape differ from supacode's dictionary/set approach.

Shape similarity: low

- Supacode's bridge is organized around terminal workspace commands. Quay's bridge is organized around terminal session state and host effects.

Verdict: INDEPENDENT

### `GhosttySurfaceView+IME.swift`

Closest supacode analog: `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift` keyboard and `NSTextInputClient` sections

Structural similarity: low to medium

- Some API names are fixed by AppKit: `keyDown`, `keyUp`, `flagsChanged`, `insertText`, `setMarkedText`, `markedRange`, `selectedRange`, and related `NSTextInputClient` methods.
- Quay now wraps key input in a `KeyInputPhase` value and separates delivery into `deliverKeyDown`, `sendKey`, and small text classification helpers.
- Supacode keeps keyboard handling inside one large surface view with additional translation state, keyboard-layout key-up suppression, accessibility, and workspace behavior.

Comment fingerprinting: clean

- No copied comments were found.

Idiosyncratic choices:

- The `KeyInputPhase` abstraction is Quay-specific and justified by separating the AppKit input phase from Ghostty delivery.
- Suppressing composing control scalars is justified by IME behavior and was verified manually by the user after rewrite.
- `ghostty_surface_quicklook_font` is bridged with `takeUnretainedValue`; this is a Quay-side correction for ownership safety.

Shape similarity: low

- The shape diverges materially from supacode: Quay has a dedicated extension file and phase object; supacode has inline handling inside a much larger view with additional event monitoring and accessibility behavior.

Verdict: INDEPENDENT

### `NSEvent+Ghostty.swift`

Closest supacode analog: keyboard event helper sections in `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`

Structural similarity: low

- Quay exposes a small `NSEvent` extension backed by Quay-local helper types for Ghostty key construction, terminal text extraction, and keyboard layout identity.
- Supacode's key translation is embedded in the surface view and includes additional translation state from Ghostty.

Comment fingerprinting: clean

- No copied comments were found.

Idiosyncratic choices:

- `currentKeyboardLayoutID()` now delegates to a `KeyboardLayoutIdentity` helper instead of using the previous array-based fallback shape. The lookup still checks current input source, current keyboard layout, and ASCII-capable layout source because those are the relevant macOS/TIS sources.
- `ghosttyCharacters` excludes private-use AppKit function-key scalars and retranslates control characters without the control modifier. This is justified by AppKit keyboard event behavior.

Shape similarity: low

- The previous residual keyboard-layout helper similarity has been removed by the hardening pass. The file is now built from small Quay-local helpers rather than the reference-like array loop.

Verdict: INDEPENDENT

Residual note: No remaining rewrite recommendation for this file.

## Previously Unclear Files

### `GhosttySurfaceView.swift`

Closest supacode analog: `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`

Structural similarity: medium at the API surface, low in implementation

- Both files must subclass `NSView`, hold a `ghostty_surface_t`, forward focus, size, mouse, scroll, and selection events, and convert AppKit coordinates to Ghostty's top-left origin.
- Quay creates the surface lazily in `viewDidMoveToWindow`; supacode creates it during initialization.
- Quay has a small `GhosttySurfaceConfig` input and a separately owned bridge; supacode owns more state directly, including IDs, shell inputs, scroll wrapper, accessibility caching, command state, and focus behavior.
- Mouse handling differs: Quay sends position before mouse button press, includes autoscroll hooks, and uses fixed left/right/middle handling; supacode has pressure/Quick Look, a broader mouse-button mapping, focus-follows-mouse, and different scroll scaling.
- Resize handling differs: Quay pushes raw backing pixel size with minimum one-pixel clamping; supacode uses cached backing size and cell-size thresholds.

Comment fingerprinting: clean

- No word-for-word matching comments were found in the checked Ghostty surface sections.
- Quay comments explain Quay-specific lifecycle and app behavior. Supacode comments in the compared sections cover different concerns such as SwiftUI split layout detachment, accessibility behavior, and background appearance.

Idiosyncratic choices:

- Lazy surface creation in `viewDidMoveToWindow`: justified by Quay needing a real AppKit window before display ID, scale, and first-responder setup.
- Bridge creation before `ghostty_surface_new`: justified because libghostty may call back during surface creation and userdata must already be valid.
- Discrete scroll-wheel scaling by `10`: idiosyncratic and Quay-specific. Supacode instead scales precise deltas by `2`, so this does not look copied.
- Autoscroll stored in the view and exposed to sibling extensions: Quay-specific behavior.
- `injectPasteText` and `performBindingAction` use `strlen` on the C string. This is mechanically valid for terminal text without embedded NULs, though the bridge rewrite already prefers `lengthOfBytes(using:)`. Consider aligning these later for consistency, but this is not a license concern.

Shape similarity: low to medium

- Required event overrides appear in similar clusters because AppKit encourages that organization.
- Within the methods, statement order and branching differ enough that this does not look derived.

Verdict: INDEPENDENT

### `GhosttySurfaceView+Services.swift`

Closest supacode analog: `NSServicesMenuRequestor` extension in `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`

Structural similarity: medium

- The method names `validRequestor(forSendType:returnType:)`, `writeSelection(to:types:)`, and `readSelection(from:)` are fixed by AppKit Services integration.
- Quay splits services into a 35-line extension file and delegates to `currentSelectionText()` and `injectPasteText()`.
- Supacode keeps the services extension in the large surface view file, supports both `.string` and `public.utf8-plain-text`, checks selection through `ghostty_surface_has_selection`, reads selection inline, and uses a custom pasteboard string accessor.

Comment fingerprinting: clean

- No copied comments were found.

Idiosyncratic choices:

- Quay accepts only `.string`: simpler than supacode and justified by current app needs.
- Quay clears pasteboard contents before writing selection: normal AppKit pattern.
- Quay treats returned service text as paste via `injectPasteText`: justified by terminal behavior.

Shape similarity: medium

- The three-method AppKit services shape is necessarily similar. The body logic is simpler and different.

Verdict: INDEPENDENT

Residual note: This file is small enough that a rewrite would be cheap if you want a zero-tolerance posture, but I do not see a copying fingerprint. The identical method names are AppKit-required selectors, not meaningful similarity.

## Summary

Verdict counts after rewrite and re-check:

| Verdict | Count | Files |
| --- | ---: | --- |
| INDEPENDENT | 6 | `GhosttyRuntime.swift`, `GhosttySurfaceBridge.swift`, `GhosttySurfaceView+IME.swift`, `NSEvent+Ghostty.swift`, `GhosttySurfaceView.swift`, `GhosttySurfaceView+Services.swift` |
| NEEDS_REWRITE | 0 | None |
| UNCLEAR | 0 | None |

Files needing rewrite, smallest first: none.

Estimated remaining rewrite effort: 0 hours.

Optional hardening effort if you want stricter-than-necessary risk reduction:

- `GhosttySurfaceView+Services.swift`: 0.5 hour to rewrite the services extension again even though current similarity is API-required.

## Patterns Observed

- The original highest-risk area was the libghostty/AppKit boundary. That has now been structurally rewritten.
- No copied comment fingerprints were found after the rewrite.
- Remaining similarity is concentrated in APIs that AppKit or libghostty effectively dictate: `NSView` event overrides, `NSTextInputClient`, `NSServicesMenuRequestor`, Ghostty surface sizing, mouse coordinate forwarding, and C callback signatures.
- Quay's app logic remains distinct from supacode's product model. Quay is an SSH connection manager with connection tree, snippets, SwiftData schemas, secret resolution, and login scripts; supacode's terminal integration is tied to worktrees, split trees, agent hooks, and repository workflows.

## Verification

Commands run after the rewrite:

```sh
xcodebuild build -project Quay.xcodeproj -scheme Quay -destination 'platform=macOS'
xcodebuild test -project Quay.xcodeproj -scheme Quay -destination 'platform=macOS'
```

Results:

- Build succeeded.
- Test suite succeeded: 114 tests across 14 suites.
- Manual QA: user reported that everything works after the rewrite.

## Residual Risk

I do not see remaining files that need rewrite for independence from supacode.

The remaining risk is ordinary integration risk, not copying risk: terminal input, IME composition, Services, pasteboard, resize, mouse behavior, config reload, and close/disconnect should continue to be smoke-tested when GhosttyKit or macOS behavior changes.
