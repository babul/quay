<!-- Managed in oss-platform: shared/guidelines/30-branches-and-prs.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh oss-platform; edits here are overwritten. -->

## Branches and merging

### Branch naming

Branch anything non-trivial. A one-line docs fix on the integration branch is fine; anything with
a story gets a branch named `{prefix}/sc-{story-number}-{slug}`:

- **`{prefix}`** — the author's name (e.g. `babul/`) for feature work, or `feature/`, `fix/`,
  `chore/` for categorised work.
- **`sc-{story-number}`** — the Shortcut story number.
- **`{slug}`** — a short kebab-case description.

Examples: `babul/sc-1234-add-export-button`, `fix/sc-1235-sort-column`.
A hotfix with no story: `fix/{slug}`.

### Landing a branch: squash merge, no PRs

The OSS silo has one developer. The second-agent review and the repo's gate already run before
every commit, so a pull request adds ceremony and no reviewer.

- Branch, and commit there once each change is gated and reviewed (conventional format, no story
  tag; see **Commits**). Then squash-merge locally into the integration branch and delete the
  branch. **Never assume `main`**: confirm the integration branch in this repo's guidelines first.
- The squash commit takes the integration-branch format, `[sc-{n}] {description}`. Its body
  carries what a PR description would have: **why** the change exists, anything a later reader
  would otherwise have to reverse-engineer (a non-obvious root cause, why the naive fix fails),
  and what was **not** verified. Refer to other stories by title only (see **Story ↔ commit
  linking**).
- Before merging, update the integration branch from its remote, so the squash lands on what is
  actually deployed.
- Open a PR only when the user asks for one. It then takes the title `[sc-{n}] {description}`,
  and its commits keep the `sc-` branch format; do not "fix" one to match the other.
