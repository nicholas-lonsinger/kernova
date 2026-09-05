---
name: freshen-main
description: >-
  Fast-forward the local default branch onto the remote after a pull request
  merges, and report what happened in one line. Use right after confirming a
  squash merge landed, and whenever the local default branch is stale —
  especially from inside a git worktree, where the branch is checked out in
  another directory and the worktree-isolation guard blocks a direct `git -C`
  against it.
argument-hint: "[--remote <name>]"
---

# Freshen the default branch

A squash merge advances the branch on the remote and leaves the local ref
where it was. From a worktree session that ref cannot be moved by hand: it is
checked out in another directory, so no in-worktree git command touches it,
and ad-hoc `git -C <other-checkout>` is refused by the worktree-isolation
guard. One script owns the operation instead.

## Run it

From anywhere inside the repository, in the foreground — it is one fetch and
one fast-forward:

```bash
.agents/skills/freshen-main/freshen-main.sh
```

Add `--remote <name>` for a repo whose upstream is not `origin`.

Run it after `gh pr view <N> --json state -q .state` reports `"MERGED"` — not
before. Merging and freshening are separate steps, and a fast-forward attempted
against a PR that has not actually merged reports `current` and moves nothing.

## Reading the result

The only stdout line is the verdict: `freshen-main: verdict=<token>
branch=<name> [path=<checkout>]`.

| Verdict | Exit | Meaning | Next action |
|---|---|---|---|
| `fast-forwarded` | 0 | The local branch moved, in the checkout `path=` names | Done |
| `current` | 0 | Already at the remote's tip | Done |
| `diverged` | 0 | The local branch has commits the remote lacks | Leave it — the user's to resolve; never force it |
| `dirty` | 0 | A fast-forward was possible but that checkout refused it: local changes or an operation in progress | Leave it — the user's to resolve |
| `not-checked-out` | 0 | No worktree has the branch checked out | Nothing to move |
| `setup-error` | 1 | Not in a repository, the fetch failed, the default branch is unresolvable, or a bad argument; `reason=` says which | Fix the environment or invocation; do not retry blindly |

Every verdict but `setup-error` is a normal outcome. Do not reach for raw git
to force a result the script declined to produce.

## Do not hand-roll it

Never substitute `git -C <path> merge`, `git fetch origin main:main`, or a
`cd` into the other checkout. The guard exists to keep a worktree session
from mutating a checkout it is not scoped to; this script is the narrow,
reviewed exception to it, and widening that exception one command at a time
defeats it.
