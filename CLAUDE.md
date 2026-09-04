# CLAUDE.md

The project's operating guide — build commands, architecture summary, and the coding/testing/review/git conventions — is agent-neutral and lives in [AGENTS.md](AGENTS.md), imported here so it loads into context every session:

@AGENTS.md

Deep-dive documentation is indexed in [docs/README.md](docs/README.md) — read those files on demand when AGENTS.md points at them. Everything below is Claude Code-specific.

## Worktree branch naming and pushing

Worktrees start on an auto-generated `worktree-<name>` branch (the harness also
mangles any `/` in the name to `+`). **Leave that scratch branch named as-is —
never `git branch -m` it.** `EnterWorktree` tracks the branch by the name it
generated, and `ExitWorktree(remove)` only tears the local branch down while that
name is intact; rename it and the removal silently orphans the branch, which is
how merged local branches pile up. Don't try to pick a name before starting
anyway — the right one depends on the full scope of the work, which you only know
once it's ready to push.

When the work is ready to push, give the **remote** branch a clean
`<type>/<short-description>` name (the convention in AGENTS.md's Branch Naming
section) while the local branch keeps its `worktree-` name — and because the
names differ, a bare `git push` pushes nothing, so **every push spells the
refspec**:

```bash
git push -u origin HEAD:<type>/<short-description>   # first push; -u so `git status -sb` tracks the remote
git push origin HEAD:<type>/<short-description>      # every later push: same refspec (add -f after a rebase)
```

Pass `--head <type>/<short-description>` to `gh pr create`, and verify after
each push with `git status -sb` — no `[ahead N]` means the push landed.
**Never push the `worktree-` scratch name to origin** (no bare
`git push -u origin HEAD`); a PR's head branch is always the clean name.
**Always push before exiting the worktree**: `ExitWorktree(remove)` drops
*unpushed* commits silently.

## Post-merge cleanup in an `EnterWorktree` session

AGENTS.md's post-merge steps assume the checkout that holds `main`. An
`EnterWorktree` session is not it: `main` is checked out in the primary
checkout, so nothing run from here advances it, and the worktree isolation
guard refuses ad-hoc `git -C <primary-checkout>` commands. After confirming
the merge landed (`gh pr view <N> --json state -q .state` → `"MERGED"`),
fast-forward `main` in that checkout rather than from this worktree — the
`gittools:freshen-main` skill does exactly this; prefer it over hand-rolling.

Then, still inside this worktree, drop the branch's now-redundant commits:

```bash
git fetch origin main && git reset --hard origin/main
```

Squash merging rewrites the work into a new commit, so the branch keeps
commits `main` never gains and every later check reads them as unmerged work —
which is what strands the worktree when a session ends without
`ExitWorktree(remove)`. The reset is safe once state is `"MERGED"`: the work is
on `main` as the squash commit, and the reset leaves this worktree matching it.

Left-behind worktrees are removable the same way: verify `gh pr list --head
<remote-branch> --state all` reports `MERGED`, then `git worktree remove <path>`
(add `--force` if Xcode left an `xcuserstate` behind) and `git branch -D
<worktree-branch>`.

## Matching review effort to the diff

`/code-review low` for trivial/mechanical diffs; `medium` (precision-biased —
"findings a maintainer would act on") as the default for bug fixes; `high`/`xhigh`
(recall-biased — "err on the side of surfacing", uncertain findings expected by
design) for features, redesigns, and the clipboard, vsock, and networking
subsystems where theoretical races are often real. Findings from recall-biased runs
especially must clear the severity bar in [docs/REVIEW.md](docs/REVIEW.md) before
being filed.

## Post-Commit

After a commit/push, if any new preferences or insights emerged during the work,
ask the user if they'd like to add them to memory.
