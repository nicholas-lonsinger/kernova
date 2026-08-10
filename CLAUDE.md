# CLAUDE.md

The project's operating guide — build commands, architecture summary, and the coding/testing/review/git conventions — is tool-neutral and lives in [AGENTS.md](AGENTS.md), imported here so it loads into context every session:

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
section) with an explicit refspec while the local branch keeps its `worktree-`
name:

```bash
git push -u origin HEAD:<type>/<short-description>   # remote/PR gets the clean name; local stays worktree-…
git push origin HEAD:<type>/<short-description>      # every later push: same refspec (add -f after a rebase)
```

The local↔remote name mismatch is deliberate: the local `worktree-` branch is a
throwaway that `ExitWorktree` deletes on exit, so only the remote name — the one
humans and GitHub see — has to be clean. The cost of the mismatch is that
**every push must spell the refspec**: with `push.default` unset (git's default
is `simple`) and the local/remote names differing, a bare `git push` refuses to
push — depending on git version/config it fails loudly (`fatal: The upstream
branch of your current branch does not match…`) or prints only an easy-to-miss
hint, but either way nothing is pushed. The `-u`
on the first push doesn't change that; it exists so `git status -sb` tracks the
remote branch. So push with `git push origin HEAD:<type>/<short-description>`
every time (add `-f` after a rebase), pass `--head <type>/<short-description>`
to `gh pr create`, and verify after each push with `git status -sb` — no
`[ahead N]` means the push landed.
**Always push before exiting the worktree** so the work is safe on origin:
`ExitWorktree(remove)` discards the local commit, and it drops *unpushed* commits
silently.

**Never push the `worktree-`-prefixed scratch name to origin** — that means no
bare `git push -u origin HEAD` on the first push; always name the clean remote
ref in the refspec. A PR's head branch must always be the clean
`<type>/<short-description>` name.

## Post-merge cleanup in an `EnterWorktree` session

AGENTS.md's post-merge steps assume the checkout that holds `main`. An
`EnterWorktree` session is not it: `main` is checked out in the primary
checkout, so nothing run from here advances it, and the worktree isolation
guard refuses ad-hoc `git -C <primary-checkout>` commands. After confirming
the merge landed (`gh pr view <N> --json state -q .state` → `"MERGED"`),
fast-forward `main` in that checkout rather than from this worktree.

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
design) for features, redesigns, and the clipboard and vsock subsystems
where theoretical races are often real. Findings from recall-biased runs
especially must clear the severity bar in [docs/REVIEW.md](docs/REVIEW.md) before
being filed.

## Post-Commit

After a commit/push, if any new preferences or insights emerged during the work,
ask the user if they'd like to add them to memory.
