#!/usr/bin/env bash
# Sets up the checkout it lives in as a working worktree, once. A marker in
# the checkout's own git directory records the run, so every later call —
# from any entry point, in any session — returns immediately:
#
#   1. copy the gitignored local files listed in .worktreeinclude from the
#      main checkout (never overwriting; only in a linked worktree)
#   2. sweep dead LaunchServices registrations and orphaned DerivedData
#      arenas (Tools/ghosts.sh --sweep)
#   3. write this checkout's buildServer.json (Tools/lsp-config.sh)
#
# This is the only implementation; each entry point is a one-line call:
#
#   .githooks/post-checkout  — every branch checkout, so a plain
#                              `git worktree add` sets up on creation and a
#                              worktree that predates `make install-hooks`
#                              catches up on its next `git switch`
#   .claude/settings.json    — Claude Code's SessionStart and EnterWorktree
#                              hooks. Claude Code creates worktrees with the
#                              repository's git hooks disabled (its worktrees
#                              doc records the same refusal of repository-
#                              supplied commands for filter drivers since
#                              2.1.247), so post-checkout never fires for a
#                              worktree it creates.
#
# Best-effort by design: always exits 0, so a failed step can never fail the
# checkout or session that triggered it, and `make doctor` / `make ghosts`
# report whatever was left undone. Progress goes to stdout; a caller that
# must stay quiet redirects it.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

# The marker lives beside git's own per-checkout state (.git/ for the main
# checkout, .git/worktrees/<name>/ for a linked one), so it needs no
# gitignore entry and disappears with the worktree.
git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
[ -n "$git_dir" ] || exit 0
marker="$git_dir/kernova-worktree-setup"
[ -e "$marker" ] && exit 0

# ---- 1. inherit .worktreeinclude files from the main checkout --------------

# git-dir equals git-common-dir exactly when this is the main checkout, where
# source and destination would be the same file.
common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ "$git_dir" != "$common_dir" ] && [ -f .worktreeinclude ]; then
    main_root=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    if [ -n "$main_root" ] && [ -d "$main_root" ]; then
        while IFS= read -r path || [ -n "$path" ]; do
            case "$path" in '' | '#'*) continue ;; esac
            [ -e "$path" ] && continue            # never overwrite
            [ -f "$main_root/$path" ] || continue # no source to copy
            # Same safety rule the native consumers apply: only gitignored
            # paths are eligible, so a tracked file can never be shadowed
            # by a stale local copy.
            git check-ignore -q -- "$path" || continue
            mkdir -p "$(dirname "$path")" && cp "$main_root/$path" "$path"
        done <.worktreeinclude
    fi
fi

# ---- 2. sweep worktree debris ------------------------------------------------

if [ -x Tools/ghosts.sh ]; then
    Tools/ghosts.sh --sweep || true
fi

# ---- 3. write this checkout's Swift language-server config -------------------

# buildServer.json names an absolute build root, so it is written per checkout
# rather than copied in step 1. The script prints a one-line `make install-lsp`
# hint and succeeds when xcode-build-server is absent — installing software is
# never a checkout's job, and a missing optional tool must not fail one.
if [ -z "${CI:-}" ] && [ ! -e buildServer.json ] && [ -x Tools/lsp-config.sh ]; then
    Tools/lsp-config.sh || true
fi

touch "$marker" 2>/dev/null || true
exit 0
