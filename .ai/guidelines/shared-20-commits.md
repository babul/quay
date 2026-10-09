<!-- Managed in oss-platform: shared/guidelines/20-commits.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Commits

### When you may commit without asking

This section is the project-level opt-in that a global "never commit without explicit
confirmation" default asks for. It overrides that default **only** on these terms.

- **Committing without asking is allowed once the change has passed a second-agent review**
  (see **Reviewing changes**). Where a repo works by squash-merging locally, the same applies to
  the squash merge. The review is a gate, not a formality: if it reports anything unresolved,
  stop and surface it instead of committing. Without a clean review, ask first.
- **The review has to have covered the exact content being committed**, not an earlier version.
  Any post-review edit means re-reviewing first; `git diff` against what the reviewer saw is the
  check. If they differ, the permission to commit without asking has lapsed.
- **The repo's own build-and-test gate must also pass** on that final content. A clean review over
  a broken build is not a pass.
- **Pushing without asking is allowed on the same terms, unless the push deploys to
  production.** The commits pushed must all be ones this session made and saw reviewed and gated,
  and the repo's pre-push hook must pass. This repo's own guidelines say which branches deploy
  to production; when they do not say, treat the push as production.
- **Still ask before:** a push that deploys to production, or that carries commits you did not
  make (check `git log @{upstream}..` before pushing); force-pushing or rewriting published
  history; tagging, releasing or uploading a build.
- Never bypass a hook: no `--no-verify`, no `-n`, no `HUSKY=0`. If a hook fails, fix the cause.
  The one exception is a release step that a repo's own guidelines document with an explicit hook
  skip for the generated release commit; follow that runbook exactly and skip nothing else.

### What goes in a commit

- Only stage files you actually changed. Never sweep unrelated files into a commit.
- Write the message for **why**, not what. Record decisions and constraints that would be
  expensive to rediscover.

### Message format

**A repo with a Shortcut team** (see **Tracking work in Shortcut**) names its stories in commits,
in the format the table below gives for the branch; check the branch name first. **A repo with no
Shortcut team** uses conventional commits everywhere, with no story tag.

| Where you commit | Format | Example |
| --- | --- | --- |
| A branch containing `sc-{n}` | Conventional commit, no story tag — the branch carries it | `fix: handle an expired session on retry` |
| The integration branch (`main` or `develop`), with a story | `[sc-{n}]` and a plain description, no conventional prefix | `[sc-1234] Add user authentication feature` |
| The integration branch, no story | `[sc-0]` and a conventional prefix | `[sc-0] chore: update dependencies` |
| Any other branch, no story | Conventional commit | `feat: add auth` |

- Wrong: `[sc-1234] fix: …` on an `sc-` branch, `fix: … [sc-1234]` anywhere, and
  `[sc-1234] feat: …` on the integration branch.
- A squash merge lands one commit on the integration branch, so it takes that format — the story
  number goes in the squash message even though the branch carried it.
- If you are committing feature work to the integration branch and no story number is known,
  stop and ask rather than defaulting to `[sc-0]`. `[sc-0]` is for genuinely system-level work.
- Commits made before these rules may use other formats; do not rewrite history to match.
