#!/usr/bin/env bash
#
# Fetch (with prune) and fast-forward the primary checkout's `main` onto
# origin/main — the one cross-checkout git operation the repo sanctions.
# Squash merges land on origin without moving the local `main` ref, and a
# worktree session cannot advance a branch checked out in the primary
# checkout: no in-worktree git command can move it, and the harness
# worktree-isolation guard refuses ad-hoc `git -C <primary>`. This vetted
# script is the supported route; the post-merge routine in CLAUDE.md runs it.
#
# Quiet and best-effort: prints only when it moves `main`; skips silently
# when `main` is current, diverged, not checked out in the primary, or the
# primary is mid-rebase (detached HEAD). Exits nonzero only when the fetch
# itself fails (offline).

set -uo pipefail

git fetch --prune --quiet origin 2>/dev/null || exit 1

main_root=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main_root" ] || exit 0
[ "$(git -C "$main_root" symbolic-ref -q --short HEAD 2>/dev/null)" = "main" ] || exit 0
git merge-base --is-ancestor origin/main refs/heads/main 2>/dev/null && exit 0
git -C "$main_root" merge --ff-only --quiet origin/main 2>/dev/null \
    && echo "freshen-main: fast-forwarded main in $main_root"
exit 0
