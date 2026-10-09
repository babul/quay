<!-- Managed in oss-platform: shared/guidelines/10-tracking-work.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh ~/Sandbox/oss-platform; edits here are overwritten. -->

## Tracking work in Shortcut

Work is tracked in Shortcut, **OSS** workspace, via the `shortcut-myoss` MCP
server. Each repo has one team, all on the "Standard" workflow:

| Repo | Team | Mention |
| --- | --- | --- |
| quay | **Quay** | `quay` |
| oss-platform | **Platform** | `platform` |

**Platform** is for cross-repo coordination and tooling only: shared guidelines, sync and status
scripts, workflow policy. A product feature that spans repos still gets one story per repo team,
related to each other; it never lives on Platform.

**A story goes on the team of the repo where the change will be made, not the repo you were
working in when you found it.** Filing on another team's board still follows the rules below:
preauthorized only when it blocks your story, otherwise ask.

- The `sc-{number}` in branch names, PR titles and commit messages *is* the story id —
  `[sc-1234]` is story 1234. Look a story up before using a number; never invent one.
  `[sc-0]` means "no story".
- **The lifecycle every team uses is Backlog → To Do → In Progress → In Review → Done.** No other states
  are used.
- **To find the next story**, search `team:<mention> !is:done`, take the highest `Priority`
  (Highest, High, Medium, Low, Lowest), and read its comments before starting — anything whose
  order matters carries a `**Sequencing:**` comment naming what must come first and why. Skip
  anything marked blocked on another story or on a product decision. The priority field is the
  source of truth; the user overrides it freely.
- Work that outlives the session — follow-up defects, deferred cleanups, review findings —
  belongs in a story, not only in the conversation. **An ordering is that kind of work too**: if
  you rank the backlog, record it on the stories before the session ends, or the next session
  re-derives it and gets a different answer.

### What you may change without asking

Creating or changing a story is outward-facing and visible to the team, so the boundary is
explicit. **Anything not named here as preauthorized needs asking first** — the lists are
examples, not an exhaustive inventory.

- **Preauthorized, on this repo's team:**
  - Moving the story you are actively working to **In Progress** when you start and
    **Done** when its work lands on the integration branch, where the automations did
    not already move it (see below), and assigning it to the user.
  - Commenting results, measurements or findings on it.
  - **Filing a discovered defect or follow-up** — a bug found while working, a review finding, a
    deferred cleanup — in To Do, and saying so. File it rather than folding it into the
    change in hand.
- **One exception on another team's board:** filing a story for work that is *blocking* a story
  you are working on (for example a missing server endpoint a client story needs), and relating
  the two. The test is that your story is already blocked; work that would merely be nice is
  planned work, so ask.
- **Ask first** — including but not limited to: creating planned work (an epic, a requested
  feature), rewriting a description, changing a title, labels, priority or estimate, deleting or
  archiving a story, touching a story you are not working on, moving anything into an unused
  state, and moving an active story *backwards*. Say which team and state you intend.

### Let the automations advance stories, then check

Shortcut's VCS handlers advance stories: a branch or commit naming a story moves it to
**In Progress**, and a merge is meant to move it to **Done**. Let them, and do
not move a story they have already moved. They have been observed not to fire for local squash
merges, so check the board after a push, and move the story by hand only when it was left
behind.

### Story ↔ commit linking

A story owns **only its own commits, branches and PRs**. They attach to a story solely through the
`sc-{number}` in the branch name, the squash commit's `[sc-{n}]`, or a PR title. That automatic
VCS link is the only legitimate way work lands on a story.

- **Never manually attach a commit or PR to a story it does not belong to.** Before adding any
  external link to a story, confirm it belongs to that exact story.
- **To connect two stories, use a related-story relation — never cross-link their work.** A
  feature that spans repos gets one story per repo, related to each other.
- **Never write another story's `sc-####` token in a commit message or PR body.** Shortcut's
  GitHub integration scans the whole text and attaches the commit or PR to every story it finds,
  so a "follow-ups" list naming other stories silently attaches this work to all of them. Refer to
  other stories by title only. These links are sticky: a pushed commit cannot be reworded, editing
  a PR body does not detach it, and there is no API to unlink — the badge has to be removed by
  hand in the Shortcut UI.
