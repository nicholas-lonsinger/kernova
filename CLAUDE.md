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

In an `EnterWorktree` session (the usual case), after confirming a merge landed
(`gh pr view <N> --json state -q .state` → `"MERGED"`), **stay in the worktree** —
do not `ExitWorktree`. Just fast-forward the primary checkout's `main` from
inside the worktree:

- `git -C <primary-checkout-path> pull --prune --ff-only` — `git -C <path>` runs
  this one command as if in the primary checkout (where `main` is checked out),
  so it fetches, fast-forwards `main` onto the squash commit, and drops the
  now-stale `origin/<type>/<short-description>` remote-tracking ref — all without
  leaving the worktree. A plain `git fetch --prune` from inside the worktree
  would only update the shared `origin/main` ref, not the local `main` branch
  pointer, which is why this targets the primary checkout. Resolve
  `<primary-checkout-path>` at runtime — it is the first entry of
  `git worktree list` (the one with no `.claude/worktrees/` segment), e.g.
  `git -C "$(git worktree list --porcelain | head -1 | cut -d' ' -f2)" pull --prune --ff-only`.
  The worktree and its scratch branch are left in place for continued or
  follow-up work.

Working directly in a checkout (no `EnterWorktree` session), follow the
tool-neutral post-merge steps in AGENTS.md instead.

## Matching review effort to the diff

`/code-review low` for trivial/mechanical diffs; `medium` (precision-biased —
"findings a maintainer would act on") as the default for bug fixes; `high`/`xhigh`
(recall-biased — "err on the side of surfacing", uncertain findings expected by
design) for features, redesigns, and the clipboard/File-Provider/vsock subsystems
where theoretical races are often real. Findings from recall-biased runs
especially must clear the severity bar in [docs/REVIEW.md](docs/REVIEW.md) before
being filed.

## Post-Commit

After a commit/push, if any new preferences or insights emerged during the work,
ask the user if they'd like to add them to memory.
