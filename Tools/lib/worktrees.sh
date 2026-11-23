# What removing a worktree would lose, for Tools/prune-worktrees.sh and the
# after-merge skill. Sourced, never run; git runs in the caller's repository.

# shellcheck shell=bash

# worktree_clean <worktree> — nothing uncommitted: no staged, unstaged or
# untracked non-ignored change, and no index entry that skip-worktree,
# assume-unchanged or a sparse checkout hides from `git status`. No optional
# locks: a plain status takes the worktree's index.lock to refresh it, which
# can fail a git command running there.
worktree_clean() {
    local st flags
    st=$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=normal 2>/dev/null) || return 1
    [ -z "$st" ] || return 1
    flags=$(git --no-optional-locks -C "$1" ls-files -v 2>/dev/null) || return 1
    ! grep -q '^[a-zS] ' <<<"$flags" && [ "$(git -C "$1" config --bool core.sparseCheckout)" != true ]
}

# content_on <ref> <commit> — some first-parent commit of <ref>, from the merge
# base with <commit> forward, is one that merging <commit> into changes
# nothing. A squash-merged branch passes even after later commits on <ref>
# edit the same lines; content no such commit ever held fails.
#
# Only the merge bases and the commits touching a path <commit> changes are
# tried: that merge's result depends on no other path, so a commit that
# touches none of them answers exactly as the last one before it that did.
content_on() {
    local ref=$1 commit=$2 bases base changed paths='' candidates='' c
    bases=$(git merge-base --all "$ref" "$commit" 2>/dev/null) && [ -n "$bases" ] || return 1
    # A path git has to quote (a newline in its name) matches no literal
    # pathspec, which only drops candidates, and so only keeps.
    while IFS= read -r base; do
        changed=$(git -c core.quotePath=false diff --no-renames --name-only "$base" "$commit" 2>/dev/null) || return 1
        [ -n "$changed" ] && paths+="$changed"$'\n'
    done <<<"$bases"
    if [ -n "$paths" ]; then
        # shellcheck disable=SC2086 # one object name per word
        candidates=$(sort -u <<<"${paths%$'\n'}" | tr '\n' '\0' |
            xargs -0 git --literal-pathspecs rev-list --first-parent --reverse "$ref" --not $bases -- 2>/dev/null) || return 1
    fi
    while IFS= read -r c; do
        [ -n "$c" ] && merge_changes_nothing "$c" "$commit" && return 0
    done <<<"$bases
$candidates"
    return 1
}

# merge_changes_nothing <base> <commit> — merging <commit> into <base> cleanly
# yields <base>'s own tree.
merge_changes_nothing() {
    local tree merged
    tree=$(git rev-parse --verify -q "$1^{tree}") || return 1
    merged=$(git merge-tree --write-tree "$1" "$2" 2>/dev/null) || return 1
    [ "${merged%%$'\n'*}" = "$tree" ]
}
