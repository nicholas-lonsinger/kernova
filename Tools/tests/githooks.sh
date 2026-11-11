#!/usr/bin/env bash
# Fixture tests for .githooks/: a tool a hook runs, started the way git starts
# the hook (GIT_DIR naming a linked worktree's gitdir), sees none of the hook's
# repository variables and still finds that worktree from its directory.

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

git init -q -b main "$tmp/repo" && git -C "$tmp/repo" commit -q --allow-empty -m init &&
    git -C "$tmp/repo" worktree add -q -b wt "$tmp/wt" || exit 1
gitdir=$(git -C "$tmp/wt" rev-parse --absolute-git-dir) || exit 1

# A stand-in for the tool a hook runs: records the repository variables it
# inherited and the worktree it resolves from its directory.
stub='#!/usr/bin/env bash
{
    for var in $(git rev-parse --local-env-vars); do
        [ -n "${!var+set}" ] && printf "inherited %s\n" "$var"
    done
    printf "toplevel %s\n" "$(git rev-parse --show-toplevel)"
} >"$STUB_LOG"
'

# expect <hook> — the hook's tool ran, inherited nothing, and resolved the
# worktree.
expect() {
    local hook=$1 log="$tmp/$1.log"
    if [ ! -s "$log" ]; then
        fail "$hook: never ran its tool"
    elif grep -q '^inherited ' "$log"; then
        fail "$hook: its tool inherited $(sed -n 's/^inherited //p' "$log" | tr '\n' ' ')"
    elif [ "$(sed -n 's/^toplevel //p' "$log")" != "$tmp/wt" ]; then
        fail "$hook: its tool resolved '$(sed -n 's/^toplevel //p' "$log")', wanted $tmp/wt"
    fi
}

# pre-push runs `make lint` from the repository root.
mkdir -p "$tmp/bin" && printf '%s' "$stub" >"$tmp/bin/make" && chmod +x "$tmp/bin/make"
sha=$(git -C "$tmp/wt" rev-parse HEAD)
(cd "$tmp/wt" && printf 'refs/heads/wt %s refs/heads/wt 0000000000000000000000000000000000000000\n' "$sha" |
    GIT_DIR="$gitdir" STUB_LOG="$tmp/pre-push.log" PATH="$tmp/bin:$PATH" \
        bash "$ROOT/.githooks/pre-push" >/dev/null)
expect pre-push

# post-checkout runs the checkout's own Tools/worktree-setup.sh.
mkdir -p "$tmp/wt/Tools" && printf '%s' "$stub" >"$tmp/wt/Tools/worktree-setup.sh" &&
    chmod +x "$tmp/wt/Tools/worktree-setup.sh"
(cd "$tmp/wt" && GIT_DIR="$gitdir" STUB_LOG="$tmp/post-checkout.log" \
    bash "$ROOT/.githooks/post-checkout" "$sha" "$sha" 1)
expect post-checkout

if [ "$FAIL" -gt 0 ]; then
    printf 'githooks fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'githooks fixtures: all passed\n'
