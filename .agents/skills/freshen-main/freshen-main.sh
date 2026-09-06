#!/usr/bin/env bash
# freshen-main.sh — fetch with prune, then fast-forward the checkout that holds
# the remote's default branch onto its remote-tracking ref.
#
# Exists for worktree sessions. A squash merge lands on the remote without
# moving the local default-branch ref, and a session running inside a worktree
# cannot advance a branch checked out in another one: no in-worktree git
# command moves it, and Claude Code's worktree-isolation guard refuses ad-hoc
# `git -C <other-checkout>` commands. This script is the vetted route — one
# fetch, one fast-forward, and on request the restore of a file in its way.
#
# Usage:
#   .agents/skills/freshen-main/freshen-main.sh [--remote <name>] [--discard <path>]...
#
#   --remote   Remote whose default branch to follow (default origin).
#   --discard  Restore <path> (repo-relative) from HEAD in the default-branch
#              checkout, then fast-forward. Refused for a path the fast-forward
#              is not blocked on, so it can only ever discard an edit a `dirty`
#              verdict named.
#
# Output is one line, the verdict, on stdout:
#   freshen-main: verdict=<token> branch=<name> [path=<checkout>] [files=<a,b>]
#
# Verdict tokens and exit codes:
#   0  fast-forwarded   the local branch moved; path= names the checkout, and
#                       discarded= the paths --discard restored first
#   0  current          already at the remote's tip
#   0  diverged         the local branch has commits the remote lacks — a
#                       situation for the user, never for a forced fix
#   0  dirty            a fast-forward was possible but refused: files= names
#                       the local edits in its way (comma-separated,
#                       repo-relative), or reason=in-progress when a merge,
#                       rebase, cherry-pick, or revert is underway there
#   0  not-checked-out  no worktree has the branch checked out (bare primary,
#                       or detached HEAD there), so nothing to move
#   1  setup-error      not in a repository, the fetch failed (offline, no
#                       such remote), the default branch is unresolvable, a
#                       bad argument, or a --discard path that is not blocking
#                       (reason=not-blocking) or could not be restored
#                       (reason=discard-failed); reason= says which

set -uo pipefail

REMOTE=origin
DISCARD=()

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

verdict() { # <exit-code> <token> [key=value ...]
    _code="$1"; _token="$2"; shift 2
    printf 'freshen-main: verdict=%s%s\n' "$_token" "${*:+ $*}"
    exit "$_code"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remote) REMOTE="${2:?--remote needs a value}"; shift 2 ;;
        --discard) DISCARD+=("${2:?--discard needs a value}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; verdict 1 setup-error "reason=usage" "argument=$1" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || verdict 1 setup-error reason=not-a-repository

git fetch --prune --quiet "$REMOTE" 2>/dev/null || verdict 1 setup-error reason=fetch-failed "remote=$REMOTE"

# The default branch, read from the remote's cached HEAD symref. A clone made
# with --single-branch, or a remote added by hand, has no refs/remotes/<remote>/HEAD
# until something sets it; --auto asks the remote and caches the answer.
default_ref=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
if [ -z "$default_ref" ]; then
    git remote set-head "$REMOTE" --auto --quiet 2>/dev/null
    default_ref=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
fi
[ -n "$default_ref" ] || verdict 1 setup-error reason=no-default-branch "remote=$REMOTE"
branch=${default_ref#"$REMOTE/"}

# The worktree with that branch checked out, which is not necessarily the
# primary one. A bare primary and a detached HEAD (mid-rebase, or a manually
# created worktree) both lack a `branch` line, so neither ever matches.
root=$(git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { if (substr($0, 8) == want) { print path; exit } }
')
[ -n "$root" ] || verdict 0 not-checked-out "branch=$branch"

git merge-base --is-ancestor "$default_ref" "refs/heads/$branch" 2>/dev/null \
    && verdict 0 current "branch=$branch"
git merge-base --is-ancestor "refs/heads/$branch" "$default_ref" 2>/dev/null \
    || verdict 0 diverged "branch=$branch" "path=$root"

# An operation underway in that checkout is the user's to finish: git refuses
# the merge, and no file list would explain why.
git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ -e "$git_dir/$marker" ] && verdict 0 dirty "branch=$branch" "path=$root" reason=in-progress
done

# The fast-forward itself. Under LC_ALL=C a refusal lists each blocking path
# on its own tab-indented line — a tracked edit or an untracked file the merge
# would overwrite — and success prints nothing.
attempt() { # prints the blocking paths, one per line; empty on success
    LC_ALL=C git -C "$root" merge --ff-only --quiet "$default_ref" 2>&1 >/dev/null \
        | awk '/^\t/ { sub(/^\t/, ""); print }'
}
moved() { git merge-base --is-ancestor "$default_ref" "refs/heads/$branch" 2>/dev/null; }
csv() { printf '%s\n' "$@" | paste -sd, -; }

files=$(attempt)
moved && verdict 0 fast-forwarded "branch=$branch" "path=$root"

if [ "${#DISCARD[@]}" -gt 0 ]; then
    for path in "${DISCARD[@]}"; do
        printf '%s\n' "$files" | grep -qxF -- "$path" \
            || verdict 1 setup-error reason=not-blocking "path=$path" "files=$(csv "$files")"
        git -C "$root" checkout --quiet -- "$path" 2>/dev/null \
            || verdict 1 setup-error reason=discard-failed "path=$path"
    done
    files=$(attempt)
    moved && verdict 0 fast-forwarded "branch=$branch" "path=$root" "discarded=$(csv "${DISCARD[@]}")"
fi

[ -n "$files" ] && verdict 0 dirty "branch=$branch" "path=$root" "files=$(csv "$files")"
verdict 0 dirty "branch=$branch" "path=$root"
