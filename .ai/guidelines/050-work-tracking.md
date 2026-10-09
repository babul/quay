## Work tracking

The shared **Tracking work in Shortcut** and **Commits** rules apply. Quay's specifics:

- Board: team **Quay** in the `myoss` workspace,
  https://app.shortcut.com/myoss/stories/space/16891
- Add the `shortcut-myoss` MCP server (Shortcut's hosted endpoint, authorized against the OSS
  workspace) with
  `claude mcp add --transport http --scope local shortcut-myoss https://mcp.shortcut.com/mcp`,
  then `/mcp` to log in. The `shortcut-aliada` and `shortcut-clayton` servers are other
  workspaces and cannot see Quay stories.
- `docs/` is for how things work and why; what is left to do, including live-verification
  checklists, lives in Shortcut. When a design
  note in `docs/` spawns implementation steps, file them as stories under an epic and link the
  note from the epic, rather than adding a plan file next to it.
