# Git Workflow Mechanics

Branch naming and the commit-message format live in [CLAUDE.md](../CLAUDE.md#git-workflow) — they apply to every commit. This file covers the machinery around getting a branch onto `main`: scratch-branch handling, branch protection, the merge procedure, and post-merge cleanup.

## Worktree scratch branches

Worktrees start on an auto-generated `worktree-<name>` branch (the harness also mangles any `/` in the name to `+`). Treat that as a throwaway scratch branch: do the work on it without renaming up front. Don't try to pick a branch name before starting — the right name depends on the full scope of the work, which you only know once it's ready to push.

When the work is ready to push to origin, rename the scratch branch to a clean `<type>/<short-description>` and push it under that same name so the local branch and the origin/PR branch match:

```bash
git branch -m <type>/<short-description>        # rename the scratch branch in place
git push -u origin <type>/<short-description>   # local and remote now match
```

**Never push the `worktree-`-prefixed scratch name to origin.** It is a local implementation detail; a PR's head branch must always be the clean `<type>/<short-description>` name. (Renaming a branch on GitHub *after* a PR exists does not retarget the PR — it closes it — so name it correctly at first push.)

## Branch protection (GitHub Rulesets)

`main` is protected via GitHub **Rulesets** (Settings → Rules → Rulesets), not the legacy "Branch protection rules" page — use Rulesets vocabulary when discussing or changing protection:

- There is no "Do not allow bypassing the above settings" toggle. The equivalent is the **Bypass list** — an empty bypass list means *nobody* (including admins) can bypass, which is the strictest setting.
- Active rulesets (as of 2026-05): "Block Delete & Force Push Main" and "swift-format before merge" (requires the `swift-format` GitHub Actions check, strict mode, no bypass actors).
- Inspect via `gh api repos/nicholas-lonsinger/kernova/rulesets` and `gh api repos/…/rulesets/<id>`. Verify the current state before recommending changes — the ruleset config can evolve.
- The checked-in pre-push hook (`make install-hooks`) pairs with the swift-format ruleset.
- `delete_branch_on_merge` is enabled — remote branches are auto-deleted after merge.

## Merging PRs

Merging is rarely a single command — expect a rebase, a CI wait, and post-merge verification:

- **Auto-merge is disabled** (`gh pr merge --auto` fails with `Auto merge is not allowed for this repository`). Wait for checks to finish, then merge.
- **The head branch must be up-to-date with `main`** (ruleset "require branches to be up to date"). If `main` moved since the branch was cut, `gh pr merge` fails with `the head branch is not up to date with the base branch`. Fix: `git rebase origin/main`, then `git push --force-with-lease` — which re-triggers checks.
- **Three required status checks** must pass: `build-and-test` (full `xcodebuild`, ~2–3 min, occasionally flaky on timing-sensitive vsock tests — see [docs/testing.md](testing.md#ci-timing-characteristics-macos-26-runners)), `proto-drift`, and `swift-format`.
- **Squash-merge with the PR title plus number**: `gh pr merge <N> --squash --subject "<type>: Title (#N)"`, matching the repo's existing convention.
- **Do not use `--delete-branch`.** GitHub auto-deletes the remote branch on merge; the flag additionally makes `gh` run `git checkout main` locally, which fails in worktree contexts.
- **Issue auto-close needs the keyword before *each* number.** GitHub's parser only closes the issue immediately following a `closes`/`fixes`/`resolves` keyword — `Closes #132, #249` closes #132 and silently leaves #249 open. Write `Closes #132, Closes #249` (repeat the keyword), or close the extras manually after merge. The keywords must appear in the **PR body** (with `--subject`, GitHub takes auto-close references from the PR body, not the squash commit body) — a table reference like `| #N |` does not count.
- **Keep the PR title/body in sync with the shipped code.** If commits change the PR's design or scope mid-flight, `gh pr edit <N> --title … --body …` before re-review or merge — reviewers (bot and human) read the description first, and stale framing shapes their feedback against the wrong target. The Summary/Changes/Test-plan structure applies to PR bodies too, not just commit messages.

Practical sequence: check `gh pr view <N> --json mergeStateStatus` (look for `CLEAN` vs `BLOCKED`/`BEHIND`) and `gh pr checks <N>`; if behind, rebase onto `origin/main` and force-push; wait for checks; merge with the squash-subject convention; then verify linked issues actually closed.

## Post-merge cleanup

After a successful merge, confirm it landed, then tear down the branch and sync `main`:

1. `gh pr view <N> --json state -q .state` — confirm `"MERGED"` before deleting anything.

**In an `EnterWorktree` session** (the usual case), let the tool do the teardown, then sync:

2. `ExitWorktree` with `action: "remove"`. Squash-merge leaves the worktree's commit off `main` by SHA, so the tool refuses unless you also pass `discard_changes: true` — that's expected and safe here, since the content already landed on `main` as the squash commit. This returns the session to the primary checkout and deletes the worktree and its scratch branch in one step.
3. Now in the primary checkout: `git checkout main` (if not already on it), then `git pull --ff-only` to fast-forward onto the squash commit.

**Working directly in a checkout** (no `EnterWorktree` session), delete the branch by hand instead:

2. Get off the merged branch first: `git switch main`, or `git checkout --detach` in a manually-created worktree (you can't switch to `main` there — the primary checkout holds it).
3. `git branch -D <merged-branch>` — force `-D`, since the squash commit makes `-d` reject the branch as "not fully merged".
4. `git branch -d -r origin/<merged-branch>` — drop the stale remote-tracking ref (GitHub auto-deletes the remote branch on merge).
5. `git pull --ff-only`.
