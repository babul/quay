## Summary

<!-- Why is this change being made? One or two sentences. -->

Fixes #

## Test plan

<!-- What did you run? -->

- [ ] `xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test`

## Screenshots / recording

<!-- UI changes only. Delete this section if not applicable. -->

## Checklist

- [ ] `xcodegen generate` run if `project.yml` changed
- [ ] No new plaintext secrets; no secret material written to logs or the SwiftData store
- [ ] Tests added or updated for behavior changes
- [ ] `Frameworks/GhosttyKit.xcframework` and `Quay.xcodeproj` are **not** committed
