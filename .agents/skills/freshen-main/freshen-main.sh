#!/usr/bin/env bash
# freshen-main.sh — fetch with prune, then fast-forward the checkout that holds
# the remote's default branch onto its remote-tracking ref.
#
# Exists for worktree sessions. A squash merge lands on the remote without
# moving the local default-branch ref, and a session running inside a worktree
# cannot advance a branch checked out in another one: no in-worktree git
# command moves it, and Claude Code's worktree-isolation guard refuses ad-hoc
# `git -C <other-checkout>` commands. This script is the vetted route — one
# fetch, one fast-forward, nothing else.
#
# Usage:
#   .agents/skills/freshen-main/freshen-main.sh [--remote <name>]
#
#   --remote  Remote whose default branch to follow (default origin).
#
# Output is one line, the verdict, on stdout:
#   freshen-main: verdict=<token> branch=<name> [path=<checkout>]
#
# Verdict tokens and exit codes:
#   0  fast-forwarded   the local branch moved; path= names the checkout
#   0  current          already at the remote's tip
#   0  diverged         the local branch has commits the remote lacks — a
#                       situation for the user, never for a forced fix
#   0  dirty            a fast-forward was possible but refused: local changes
#                       or an operation in progress in that checkout
#   0  not-checked-out  no worktree has the branch checked out (bare primary,
#                       or detached HEAD there), so nothing to move
#   1  setup-error      not in a repository, the fetch failed (offline, no
#                       such remote), the default branch is unresolvable, or
#                       a bad argument; reason= says which

set -uo pipefail

REMOTE=origin

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

if git -C "$root" merge --ff-only --quiet "$default_ref" >/dev/null 2>&1; then
    verdict 0 fast-forwarded "branch=$branch" "path=$root"
fi
verdict 0 dirty "branch=$branch" "path=$root"
