#!/usr/bin/env bash
# Removes the worktrees under the primary checkout's .claude/worktrees/ whose
# work is merged, then unregisters the Launch Services records of Kernova
# bundles that no longer exist.
#
#     Tools/prune-worktrees.sh [-n]
#
#   -n   print what it would remove and unregister, and what it keeps and why;
#        change nothing
#
# A worktree goes when it is not the checkout running this, no live Claude
# Code session holds its lock, nothing in it is uncommitted, and its HEAD's
# content is on origin/main, fetched first (Tools/lib/worktrees.sh), or its
# HEAD is one of a merged pull request's commits — a subagent's commit that
# the pull request carried on from. The removal is `git worktree remove`
# without --force, so git itself refuses a tree with modified or untracked
# files; ignored files (DerivedData/, artifacts/, the .worktreeinclude copies)
# go with the tree, and the branch it had checked out is deleted. A worktree
# whose folder is already gone has only its record and branch left: the record
# is dropped unless a live session holds its lock, and the branch is deleted
# when its work is merged.
#
# Claude Code locks each worktree it creates with the reason
# `claude <agent|session> <name> (pid <pid> start <time>)`, naming the process
# that owns it and that process's `ps -o lstart` in the C locale and UTC. The
# lock of a process that is gone, or whose pid now names a process started at
# another time, was left by a session that died, and is lifted for the
# removal; any other lock keeps the worktree.

set -uo pipefail

case "${1:-}" in
    '') dry='' ;;
    -n) dry=1 ;;
    *) echo 'usage: Tools/prune-worktrees.sh [-n]' >&2; exit 2 ;;
esac
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=lib/worktrees.sh
. Tools/lib/worktrees.sh
would=${dry:+would }
ref=refs/remotes/origin/main
git fetch -q origin main || echo "prune-worktrees: cannot fetch; judging against the local ${ref#refs/remotes/}" >&2
own=$(pwd -P)
listing=$(git worktree list --porcelain) || exit 1
root="$(sed -n '1s/^worktree //p' <<<"$listing")/.claude/worktrees"

squeeze() { awk '{ $1 = $1; print }' <<<"$1"; }

# kept_by <lock reason> — whether the lock keeps its worktree; sets why.
kept_by() {
    local claude='^claude (agent|session) .+ \(pid ([0-9]+)( start (.+))?\)$' pid start started
    if ! [[ $1 =~ $claude ]]; then
        why="locked: ${1:-no reason given}"
        return 0
    fi
    pid=${BASH_REMATCH[2]} start=${BASH_REMATCH[4]}
    started=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid") || return 1
    [ -z "$start" ] || [ "$(squeeze "$started")" = "$(squeeze "$start")" ] || return 1
    why="a live Claude Code session holds its lock (pid $pid)"
}

# merged_pr_holding <commit> — prints the merged pull request whose commits, as
# GitHub lists them, include <commit>: a search hit alone can be a mention.
merged_pr_holding() {
    local pr
    for pr in $(gh pr list --state merged --search "$1" --json number -q '.[].number' 2>/dev/null); do
        grep -qxF "$1" <<<"$(gh pr view "$pr" --json commits -q '.commits[].oid' 2>/dev/null)" &&
            { echo "#$pr"; return 0; }
    done
    return 1
}

gone=()
while IFS=$'\x1f' read -r wt branch locked reason; do
    [ "${wt%/*}" = "$root" ] || continue
    name=${wt#"$root/"}
    why=''
    if [ ! -d "$wt" ]; then
        if [ -n "$locked" ] && kept_by "$reason"; then
            echo "keep $name: $why"
            continue
        fi
        # git's own prune, below, drops a record no lock holds.
        echo "${would}drop record $name: its folder is gone"
        [ -n "$dry" ] || [ -z "$locked" ] || git worktree unlock "$wt" || continue
        [ -z "$branch" ] || gone+=("$branch")
        continue
    fi
    if [ "$wt" -ef "$own" ]; then
        why='the checkout running this'
    elif [ -n "$locked" ] && kept_by "$reason"; then
        :
    elif ! worktree_clean "$wt"; then
        why='uncommitted changes'
    elif ! head=$(git -C "$wt" rev-parse -q --verify HEAD); then
        why='no commit checked out'
    elif content_on "$ref" "$head"; then
        how='content on main'
    elif pr=$(merged_pr_holding "$head"); then
        how="HEAD is a commit of merged $pr"
    else
        why='work not on main'
    fi
    if [ -n "$why" ]; then
        echo "keep $name: $why"
        continue
    fi
    echo "${would}remove $name${branch:+ and branch $branch}: $how${locked:+; its lock was left by a session that died}"
    [ -z "$dry" ] || continue
    if [ -n "$locked" ]; then git worktree unlock "$wt" || continue; fi
    git worktree remove "$wt" && { [ -z "$branch" ] || git branch -q -D "$branch"; }
done < <(awk '
    function emit() { if (wt != "") print wt "\037" branch "\037" locked "\037" reason }
    /^worktree / { emit(); wt = substr($0, 10); branch = locked = reason = "" }
    /^branch refs\/heads\// { branch = substr($0, 19) }
    /^locked/ { locked = 1; reason = substr($0, 8) }
    END { emit() }
' <<<"$listing")
git worktree prune -v ${dry:+-n}
for branch in ${gone[@]+"${gone[@]}"}; do
    head=$(git rev-parse -q --verify "refs/heads/$branch") || continue
    if content_on "$ref" "$head" || merged_pr_holding "$head" >/dev/null; then
        echo "${would}delete branch $branch: its work is merged"
        [ -n "$dry" ] || git branch -q -D "$branch"
    else
        echo "leave branch $branch: work not on main"
    fi
done

# A build's bundles are registered by path, and the record outlives the
# checkout that held them.
PATH="$PATH:/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support"
lsregister -dump | awk '
    /^-+$/ { path = "" }
    /^path:/ { path = $0; sub(/^path:[ \t]*/, "", path); sub(/ \(0x[0-9a-fA-F]+\)[ \t]*$/, "", path) }
    /^identifier:[ \t]+app\.kernova($|\.)/ && path != "" { print path }
' | sort -u | while IFS= read -r path; do
    [ -e "$path" ] && continue
    echo "${would}unregister $path"
    [ -n "$dry" ] || lsregister -u "$path"
done
