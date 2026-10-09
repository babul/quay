## Work tracking

Follow-on work, deferred ideas, and live-verification checklists are tracked
as Shortcut stories, not as files under `docs/`. `docs/` is for how things
work and why; what is left to do lives in Shortcut so it is not forgotten.

- Org: `myoss` (workspace "OSS"), team **Quay**:
  https://app.shortcut.com/myoss/stories/space/16891
- Workflow "Standard": Backlog → To Do → In Progress → In Review → Done.
  Stories advance through it automatically — never move one by hand.
- **Every commit or PR for a story must name that story**, so the two stay
  linked. How depends on the branch — see "Commit messages" below.
- From Claude Code, use the `shortcut-myoss` MCP server (Shortcut's hosted
  endpoint, `https://mcp.shortcut.com/mcp`, authorized against the OSS
  workspace). Add it with
  `claude mcp add --transport http --scope local shortcut-myoss https://mcp.shortcut.com/mcp`,
  then `/mcp` to log in. The `shortcut-aliada` and `shortcut-clayton` servers
  are other workspaces and cannot see Quay stories.
- When a design note in `docs/` spawns implementation steps, file them as
  stories under an epic and link the note from the epic, rather than adding
  a plan file next to it.

### Commit messages

Stage and commit only the files you actually changed; never sweep in unrelated
ones. The subject format is decided by the branch you are on:

| Branch | Format | Example |
|---|---|---|
| Contains `sc-<id>` | Conventional commit only — the branch already carries the story | `fix: address review feedback on HLS transport` |
| `main`/`develop`, story known | `[sc-<id>]` + plain description, **no** conventional prefix | `[sc-14113] Add user authentication feature` |
| `main`/`develop`, no story (system-level) | `[sc-0]` + conventional prefix | `[sc-0] chore: update dependencies` |
| Any other branch, no story | Conventional commit only | `feat: add auth` |

So on an `sc-` branch `[sc-15615] fix: …` and `fix: … [sc-15615]` are both
wrong, and on `main` a conventional prefix after the tag is wrong.

Committing feature work to `main`/`develop` with no story number in hand: stop
and ask for one rather than reaching for `[sc-0]`.
