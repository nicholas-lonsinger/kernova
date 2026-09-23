# The worktree layout the Tools/ scripts share. Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/worktrees.sh"
#     read_worktree_layout "$REPO_ROOT" || …
#
# read_worktree_layout <checkout> sets
#
#   main_root       the primary checkout, which <checkout> is not when it is a
#                   linked worktree: `git worktree list` names the primary first
#   worktrees_root  $main_root/.claude/worktrees, where the linked worktrees live
#
# and records the registered worktrees for the two queries below. When git
# cannot list the worktrees it returns 1 and leaves everything empty.

# shellcheck shell=bash

read_worktree_layout() {
    local listing
    main_root=''
    worktrees_root=''
    worktree_paths=''
    listing=$(git -C "$1" worktree list --porcelain 2>/dev/null) || return 1
    worktree_paths=$(printf '%s\n' "$listing" | sed -n 's/^worktree //p')
    main_root=$(printf '%s\n' "$worktree_paths" | sed -n '1p')
    [ -n "$main_root" ] || return 1
    worktrees_root="$main_root/.claude/worktrees"
}

# worktree_registered <dir> — whether a `git worktree list` entry names <dir>.
# Compared by identity (same device and inode), not by spelling: git records
# each path resolved, and a caller that trashes what is not registered must
# still match a registered directory reached through a symlink.
worktree_registered() {
    local wt
    while IFS= read -r wt; do
        [ -n "$wt" ] && [ "$1" -ef "$wt" ] && return 0
    done <<<"$worktree_paths"
    return 1
}

# orphaned_worktree_dirs — one line per directory directly under worktrees_root
# that no registration names; files and symlinks are skipped. Reports nothing
# when the listing could not be read, where every directory would otherwise
# look unregistered.
orphaned_worktree_dirs() {
    [ -n "$worktrees_root" ] || return 0
    local dir
    for dir in "$worktrees_root"/*/; do
        dir=${dir%/}
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            continue
        fi
        worktree_registered "$dir" || printf '%s\n' "$dir"
    done
}
