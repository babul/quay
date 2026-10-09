<!-- Managed in oss-platform: shared/guidelines/50-tests.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Tests that earn their place

- **Show a regression test failing without its fix:** revert the fix, run the test red, restore the
  fix, run it green. A test never seen failing has not been shown to test anything.
- **A regression test that hangs on the broken code is a defective test**, even when it passes on
  the fixed code. Revert the fix and confirm it fails *fast*, with an assertion message, not by
  burning a timeout.
- **When one change fixes several defects, revert each fix individually** and confirm exactly its
  own test fails while the others pass. Reverting them all together only shows that something
  broke.
- **Assert the narrowest claim the test actually supports.** Do not infer visibility from a size,
  centring from a width, or correctness from the absence of an error.
- **Gate the operation that supersedes, rather than racing a timer.** Acting without awaiting a
  debounced or scheduled task looks safe because the margin is large, but it is a scheduling
  assumption; when it loses, the test hangs or flakes instead of failing. Use deterministic
  ordering primitives, never sleeps.
- **Prefer injecting a seam over driving the whole app**, and prefer component boundaries that take
  plain values so they can be tested without constructing services. Keep slow end-to-end and UI
  tests few and deterministic.
- **A failing test is evidence that something is wrong, not proof of the thing it claims.** Read
  what it actually measures before acting on it.
- Do not fix unrelated failing tests as part of a targeted change; file them (see **Tracking work
  in Shortcut**).
- Confirm new test files are actually compiled and collected. A suite that goes green having
  silently skipped new tests is worse than a red one; compare the test count before and after.
