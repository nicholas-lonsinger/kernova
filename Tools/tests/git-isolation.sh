#!/usr/bin/env bash
# Runs each fixture script given as an argument the way `pre-push` runs it from
# a linked worktree — working directory in the worktree, GIT_DIR naming its
# gitdir — but against a decoy repository built here, and fails a fixture that
# changes the decoy's config. `make lint` runs the fixture suite through this,
# so no fixture reaches the repository that invoked it.
#
#     bash Tools/tests/git-isolation.sh <fixture.sh, relative to the repo root>...

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# new_decoy <name> — a primary checkout under $tmp/<name> with a linked
# worktree at $tmp/<name>-wt; prints the worktree's gitdir.
new_decoy() {
    git init -q -b main "$tmp/$1" && git -C "$tmp/$1" commit -q --allow-empty -m init &&
        git -C "$tmp/$1" worktree add -q -b wt "$tmp/$1-wt" &&
        git -C "$tmp/$1-wt" rev-parse --absolute-git-dir
}

bare() { git config --file "$tmp/$1/.git/config" --get core.bare; }

# The decoy has to reproduce the failure, or a fixture that leaks would pass:
# an unisolated `git init` under its environment marks it bare.
gitdir=$(new_decoy canary) || { echo 'git-isolation: cannot build the decoy repository' >&2; exit 1; }
(cd "$tmp/canary-wt" && GIT_DIR="$gitdir" git init -q "$tmp/canary-init")
if [ "$(bare canary)" != true ]; then
    fail "canary: an unisolated git init under GIT_DIR=$gitdir left core.bare '$(bare canary)'; the decoy no longer reproduces a leak"
fi

for fixture in "$@"; do
    name=$(printf '%s' "$fixture" | tr '/.' '__')
    gitdir=$(new_decoy "$name") || { fail "$fixture: cannot build its decoy repository"; continue; }
    before=$(cat "$tmp/$name/.git/config")
    if ! (cd "$tmp/$name-wt" && GIT_DIR="$gitdir" bash "$ROOT/$fixture"); then
        fail "$fixture: failed"
    fi
    if [ "$(bare "$name")" != false ]; then
        fail "$fixture: set core.bare '$(bare "$name")' in the repository whose GIT_DIR it inherited"
    elif [ "$(cat "$tmp/$name/.git/config")" != "$before" ]; then
        fail "$fixture: changed the config of the repository whose GIT_DIR it inherited"
    fi
done

if [ "$FAIL" -gt 0 ]; then
    printf 'git-isolation: %d failed\n' "$FAIL" >&2
    exit 1
fi
