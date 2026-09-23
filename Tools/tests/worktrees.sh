#!/usr/bin/env bash
# Fixture tests for Tools/lib/worktrees.sh: builds primary checkouts holding
# registered worktrees beside stray directories under .claude/worktrees/, then
# checks the layout it reads and which directories its orphan scan reports.
# Local git only — no network — and it takes about a second.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/worktrees.sh
. "$ROOT/Tools/lib/worktrees.sh"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

# git reports worktree paths resolved, so resolve the fixture root the same way
# (on macOS mktemp answers under /var, a symlink to /private/var).
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# Pin everything git reads from the environment, so the run reports on the
# library and not on this machine's identity, global config, or caller.
#
# The repo-locating variables come first: git exports GIT_DIR, GIT_WORK_TREE
# and their companions to a hook's child processes, so a run under `pre-push`
# inherits them and every fixture command addresses the real checkout.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_PREFIX \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_QUARANTINE_PATH GIT_REFLOG_ACTION
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

new_checkout() { # <dir>
    git init -q -b main "$1" && git -C "$1" commit -q --allow-empty -m init
}

# check <name> <got> <want>
check() {
    if [ "$2" = "$3" ]; then pass; else fail "$1: got '$2', wanted '$3'"; fi
}

# expect_orphans <name> <checkout> [<dir>...] — the scan, run from <checkout>,
# reports exactly these directories.
expect_orphans() {
    local name=$1 checkout=$2
    shift 2
    if ! read_worktree_layout "$checkout"; then
        fail "$name: layout unreadable from $checkout"
        return
    fi
    check "$name" "$(orphaned_worktree_dirs)" "$(printf '%s\n' "$@")"
}

# ---- the primary layout --------------------------------------------------------

main="$tmp/main"
wts="$main/.claude/worktrees"
new_checkout "$main"
git -C "$main" worktree add -q --detach "$wts/live"
git -C "$main" worktree add -q --detach "$wts/locked"
git -C "$main" worktree lock --reason 'claude agent' "$wts/locked"

# The case the scan exists for: removal drops the registration and the
# directory, and a later write recreates the directory unregistered.
git -C "$main" worktree add -q --detach "$wts/gone"
git -C "$main" worktree remove "$wts/gone"
mkdir -p "$wts/gone/Kernova.xcodeproj/project.xcworkspace/xcuserdata/t.xcuserdatad"
touch "$wts/gone/Kernova.xcodeproj/project.xcworkspace/xcuserdata/t.xcuserdatad/UserInterfaceState.xcuserstate"

touch "$wts/stray-file"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$wts/link"

expect_orphans "from the primary" "$main" "$wts/gone"
check "main_root from the primary" "$main_root" "$main"
check "worktrees_root from the primary" "$worktrees_root" "$wts"

expect_orphans "from a linked worktree" "$wts/live" "$wts/gone"
check "main_root from a linked worktree" "$main_root" "$main"

if worktree_registered "$wts/live"; then pass; else fail "registered: live reads unregistered"; fi
if worktree_registered "$wts/locked"; then pass; else fail "registered: locked reads unregistered"; fi
if worktree_registered "$wts/gone"; then fail "registered: gone reads registered"; else pass; fi
if worktree_registered "$wts/never"; then fail "registered: a missing path reads registered"; else pass; fi

rm -rf "$wts/gone"
expect_orphans "after the orphan is gone" "$main"

# ---- a symlinked .claude/worktrees ---------------------------------------------

# git records the resolved path, so the scan's spelling of a registered
# directory differs from git's; it must still read as registered.
linked="$tmp/linked"
new_checkout "$linked"
mkdir -p "$linked/.claude" "$tmp/store"
ln -s "$tmp/store" "$linked/.claude/worktrees"
git -C "$linked" worktree add -q --detach "$linked/.claude/worktrees/live"
if git -C "$linked" worktree list --porcelain | grep -qxF "worktree $tmp/store/live"; then
    pass
else
    fail "symlinked root: git did not record the resolved path, so this case tests nothing"
fi
expect_orphans "symlinked root" "$linked"

# ---- nothing to scan -------------------------------------------------------------

plain="$tmp/plain"
new_checkout "$plain"
expect_orphans "no .claude/worktrees/" "$plain"

mkdir -p "$tmp/not-a-checkout/.claude/worktrees/stray"
if read_worktree_layout "$tmp/not-a-checkout"; then
    fail "not a checkout: the layout read succeeded"
else
    pass
fi
check "not a checkout: worktrees_root" "$worktrees_root" ''
check "not a checkout: scan" "$(orphaned_worktree_dirs)" ''

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s worktrees: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
