<!-- Managed in oss-platform: shared/guidelines/40-reviewing.md. Edit it there and run ~/.agents/shared-guidelines/sync-guidelines.sh ~/Sandbox/oss-platform; edits here are overwritten. -->

## Reviewing changes

### Every change gets a second-agent review

- Have a second agent review a change before proposing it for commit; an agent's own diff is not
  verification. A clean review is what permits committing without asking (see **Commits**).
- Scale the review to what changed. A Codex review covers every change. The simplifier only runs
  when code changed — skip it for docs, Markdown and config-only diffs, where it has nothing to act
  on.
- The order is **simplifier → automated gates → verification → review → commit**, so the review
  is the last thing to touch the change and sees it in the form committed. Docs and config-only
  diffs skip the simplifier and any gate that does not apply, never the review.

### The review must cover exactly what you commit

**Any edit that changes the committed content after a review — however small, however mechanical
— invalidates the review and requires a fresh one.** There is no size threshold. It applies to
changes the reviewer or the simplifier itself proposed: a proposal is not a review of its own
application. Re-review, then commit.

- The test is content, not chronology. An edit reverted to exactly the reviewed state needs no new
  review — `git diff` against what the reviewer saw is the check. Staging, and regenerating
  generated files that are not committed, change nothing and trigger nothing.
- Send it back to the same reviewing agent rather than starting a new one: it still has the
  context. Say what changed, and name the files that did not so it does not re-read them.
- Acting on a review finding is itself a post-review edit: apply the fix, rerun the gates it
  touches, and send it back for review. If you run the simplifier again after a review, anything
  it changes, or any of its proposals you act on, is a post-review edit too.
- **The repo's build-and-test gate has to cover the final content too.** Re-reviewing and
  rerunning are one step, not alternatives: an edit applied after a review is exactly the kind
  that compiles in a reviewer's head and not in the real toolchain. A docs-only edit needs no
  rebuild.
- This rule was written down after it was broken twice in one session: both times a simplifier's
  own proposal, with passing tests, was applied after the review and committed unreviewed.
  Committing without asking means nothing else catches it.

### A review is not the whole gate

- A reviewing agent reads code; it does not run the build or the tests. When code changed, the
  repo's own gate (build, tests, linters, and — for a user-visible change — exercising it for
  real, see **Verifying changes**) must pass before committing.
- A consistency review passes a document that is consistently missing something. When the
  question is "is anything absent", check the history and the actual behaviour, not just whether
  the file agrees with itself.
- When two reviewers disagree, prefer the argument that can be checked against the code over the
  one inferred from a symptom.

### Working with agents

- Run editing and reviewing agents in sequence, never in parallel on the same files — a reviewer
  reading files an editor is rewriting reviews a moving target. Agents in different repos may run
  in parallel.
- Wait for an agent's completion notification before acting on its work; checking for an OS
  process does not detect in-process subagents.
- Read every agent edit before trusting it. A simplifier once deleted a passing regression test
  and kept a failing invalid one.
- Tell a simplifier to propose test or assertion removals, never to make them. Coverage is not a
  simplification target.
- When delegating, write the task so a less capable agent can finish it without guessing: exact
  file paths, what to change, the expected behaviour and the pattern to follow — one solution,
  not a menu.
- **Redirect stdin in delegated shell commands** (`< /dev/null`). An agent's stdin is a pipe that
  never closes, and any tool that reads stdin when it is not a terminal blocks on it forever. `ls`
  was once aliased to `eza`, which does exactly that, and a Codex review told to "check the
  filesystem with `ls`" was found still running after ten hours. The shell config is fixed, but
  the redirect is the cheap defence against the next such tool. A stuck task hides in plain sight:
  grep for `codex-companion` and check its children, not just the long-lived `app-server` daemons.

### Codex review

Codex reviews the finished diff: after the simplifier, after the automated gates are green,
immediately before committing. It is there to catch what the tools cannot — a fix that will not
age well, a test that passes for the wrong reason, an edge case nobody considered.

- **Ask for a review, not for objections.** Frame it as a normal PR review: "Review this for
  correctness. Say CLEAN if you would approve it as-is. Report only defects you would block a
  merge on; list anything else separately as optional nits." Never prompt it adversarially ("be
  adversarial", "hunt for issues"): a reviewer told to produce findings always produces them, and
  the loop never converges.
- **Know when it is done.** Once findings stop being reproducible defects and become threshold
  tuning or taste — and Codex says as much — that is the all-clear.
- **Give it what it needs:** what changed and why; which gates you already ran and their results;
  and what it should not re-run. Its sandbox is read-only with no database or running site, so
  anything needing those fails there for environmental reasons it would otherwise report as
  findings.
- **Run it as a background agent through the Codex plugin.** Spawn the `codex:codex-rescue`
  agent in the background with a prompt that starts with `--wait`, then says this is a
  **read-only review: do not edit files** (otherwise it defaults to a write-capable run). Carry on
  with other work, and act on the result only when the agent's completion notification arrives —
  never poll for processes. A person can run the same review with `/codex:review`.
- **`--wait`, never `--background`, in that prompt.** The agent is already in the background;
  `--background` makes it detach Codex too, so it returns at once with only a job id and its
  completion means nothing. If that happens, `/codex:status <job>` and `/codex:result <job>`
  recover the review — run from the same working directory the agent ran in, because jobs are
  tracked per workspace.
- **If it never comes back**, it is usually the stdin hang above: look for `codex-companion` and
  its children, not the long-lived `app-server` daemons, and cancel with `/codex:cancel`.
- **Without the plugin**, fall back to the CLI in the foreground; the prompt file is its stdin, so
  it never inherits one:

  ```bash
  codex exec --sandbox read-only --skip-git-repo-check - < review-prompt.md
  ```

Fix or explicitly justify every finding, re-review what you changed, then commit.
