## Work tracking

Follow-on work, deferred ideas, and live-verification checklists are tracked
as Shortcut stories, not as files under `docs/`. `docs/` is for how things
work and why; what is left to do lives in Shortcut so it is not forgotten.

- Org: `myoss` (workspace "OSS"), team **Quay**:
  https://app.shortcut.com/myoss/stories/space/16891
- Workflow "Standard": Backlog → To Do → In Progress → In Review → Done.
  A branch or commit naming a story moves it to In Progress, and a merge is
  meant to move it to Done.
- **Every commit or PR for a story must name that story**, so the two stay
  linked. How depends on the branch — see "Commit messages" below.
- From Claude Code, use a Shortcut MCP server pointed at Shortcut's hosted
  endpoint (`https://mcp.shortcut.com/mcp`) and authorized against the OSS
  workspace, for example
  `claude mcp add --transport http shortcut-oss https://mcp.shortcut.com/mcp`,
  then `/mcp` to log in. A server authorized against another workspace cannot
  see Quay stories.
- When a design note in `docs/` spawns implementation steps, file them as
  stories under an epic and link the note from the epic, rather than adding
  a plan file next to it.

### Commit messages

Stage and commit only the files you actually changed; never sweep in unrelated
ones. Never bypass a hook (`--no-verify`, `-n`). Write the message for why, not
what. The subject format is decided by the branch you are on:

| Branch | Format | Example |
|---|---|---|
| Contains `sc-<id>` | Conventional commit only — the branch already carries the story | `fix: address review feedback on HLS transport` |
| `main`, story known | `[sc-<id>]` + plain description, **no** conventional prefix | `[sc-14113] Add user authentication feature` |
| `main`, no story (system-level) | `[sc-0]` + conventional prefix | `[sc-0] chore: update dependencies` |
| Any other branch, no story | Conventional commit only | `feat: add auth` |

So on an `sc-` branch `[sc-15615] fix: …` and `fix: … [sc-15615]` are both
wrong, and on `main` a conventional prefix after the tag is wrong. A squash
merge lands one commit on `main`, so it takes the `main` format.

Committing feature work to `main` with no story number in hand: stop
and ask for one rather than reaching for `[sc-0]`.

### Shipping

Pushing `main` deploys nothing. `scripts/release.sh` ships: it pushes, notarizes,
signs for Sparkle, updates the appcast on `gh-pages` and creates a GitHub
release that every installed copy of Quay offers as an update.
