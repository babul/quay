<!-- Adopted from the fragment library (story-linking), 2026-10-10. Owned by this repo: edit freely. -->

## Story ↔ commit linking

This repo's work is tracked on the **Quay** team in Shortcut
(`team:quay !is:done`). The `sc-{number}` in a branch name, commit message or PR
title *is* the story id: `[sc-1234]` is story 1234. Look a story up before using its number, and
never invent one.

A story owns **only its own commits, branches and PRs**. They attach to it only through the
`sc-{n}` in the branch name, the squash commit's `[sc-{n}]` or a PR title.

- **Never manually attach a commit or PR to a story it does not belong to.** Before adding any
  external link to a story, confirm it belongs to that exact story.
- **To connect two stories, use a related-story relation; never cross-link their work.**
- **Never write another story's `sc-####` token in a commit message or PR body.** Shortcut scans the
  whole text and attaches the commit or PR to every story it names, so a "follow-ups" list
  silently attaches this work to all of them. Refer to other stories by title. These links are
  sticky: a pushed commit cannot be reworded, editing a PR body does not detach it, and the badge
  has to be removed by hand in the Shortcut UI.
