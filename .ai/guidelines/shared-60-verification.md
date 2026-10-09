<!-- Managed in oss-platform: shared/guidelines/60-verification.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh ~/Sandbox/oss-platform; edits here are overwritten. -->

## Verifying changes

**Any change a user can see must be exercised for real before it is committed** — in a browser for
a web surface, on the simulator or a device for a native app, by running the command for a CLI.
The user should never have to ask for this. Green tests are not evidence that a UI works. This
repo's own guidelines say how to drive it; these are the principles.

### Measure, never assume

Report numbers you actually read, not values you expect. Touch targets (44pt/44px minimum),
contrast ratios, focus rings reached with a real `Tab`/keyboard press, layout at the narrowest
supported width with no horizontal overflow, both light and dark themes, reduced motion, and a
clean console or log. Each has a cheap, specific check; run it.

### Exercise the real path, not just the render

A screenshot of an initial state proves very little. Drive the actual interaction, including the
states that only appear mid-flight or on failure — progress and cancel, validation errors, an empty
list, a slow request, a signed-out session. Where a state is hard to reach naturally, use the
component's own documented events or fixtures rather than faking its markup. Prefer real data
where it is safe, and **clean up anything created** — records, uploads, and any flag toggled to
reach a state (restore it, and say so).

### Report honestly

State what was verified, and at which viewport, device and theme. Say plainly **what the automated
suites did not cover**, so nobody assumes they proved more than they did. If something could not
be exercised, say that rather than implying it passed.
