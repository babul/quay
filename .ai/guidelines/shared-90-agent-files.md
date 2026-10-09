<!-- Managed in oss-platform: shared/guidelines/90-agent-files.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## How this AGENTS.md is built

- **In a Laravel repo, use Laravel Boost instead of cribsheet.** Boost reads the same
  `.ai/guidelines/` fragments, `shared-*.md` included, and regenerates its
  `<laravel-boost-guidelines>` block in `AGENTS.md`: run
  `php artisan boost:update --no-interaction` after editing a fragment. Never run cribsheet
  there and never edit that block by hand. Never add a `CLAUDE.md` either: Claude Code would
  read it instead of `AGENTS.md`, and Boost would start writing the guidelines into it. Every
  cribsheet instruction in this section applies only to repos without Boost.
- Without Boost, `AGENTS.md` is compiled by **cribsheet** from the fragments in
  `.ai/guidelines/`, between the `<!-- cribsheet:begin -->` and `<!-- cribsheet:end sha=… -->`
  markers. Edit a fragment, never the compiled block, then recompile and commit both. Text
  outside the markers is hand-written and never touched by the compiler.
- `shared-*.md` fragments are copies of the silo guidelines in `oss-platform/shared/guidelines/`,
  which are filled in from the shared guidelines in `~/.agents/shared-guidelines/`. Change a shared
  rule there and run the `guideline-sync` skill; never edit a repo's copy. Rules specific to one
  repo go in that repo's own numbered fragments, which may add to a shared rule but must not
  contradict it.
- A rule belongs in the shared set only if it holds in every repo without naming a file, command
  or branch specific to one of them.
- **Put each rule at the highest level where it holds**: the shared guidelines for every silo, the
  silo guidelines for one silo, a repo's own fragments for one repo. A lower level states only its
  exceptions and additions, never a copy of a rule above it.
- cribsheet is the local checkout at `~/Sandbox/cribsheet`, run with bun:
  `bun ~/Sandbox/cribsheet/bin/cribsheet.js` to compile and `… check` to verify. The
  `cribsheet` package on npm is only a name placeholder: never install it or `npx` it.
- `check` exits 1 when the output is stale (recompile) and 2 when the block was edited by hand. On a
  2, cribsheet prints how the block differs from the fragments. Move the hand edit into the right
  fragment and recompile: once the block matches, cribsheet keeps its content and updates the `sha`.
  `--force` discards the edit; use it only when that is the intent.
- `AGENTS.md` is excluded from formatters (`.prettierignore`), because reformatting the block
  breaks its hash. Do not add a `CLAUDE.md` that duplicates it.
