#!/usr/bin/env bash
# Fixture tests for Tools/lib/worktrees.sh: builds primary checkouts holding
# registered worktrees beside stray directories under .claude/worktrees/, then
# checks the layout it reads, which directories its orphan scan reports, and
# which worktrees it reads as abandoned and removes.
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
# Background processes the fixtures start, stopped (and reaped, so the shell
# reports no job) on exit.
children=()
cleanup() {
    if [ "${#children[@]}" -gt 0 ]; then
        kill "${children[@]}" 2>/dev/null
        wait "${children[@]}" 2>/dev/null
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

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

# ---- stale xcode-build-server caches ---------------------------------------------

# Named the way xcode-build-server names them: the checkout's path, `/` → `-`.
bsc="$tmp/xcode-build-server"
bsc_name() { printf '%s/%s' "$bsc" "${1//\//-}"; }
mkdir -p "$(bsc_name "$main")" "$(bsc_name "$wts/live")" "$(bsc_name "$wts/locked")" \
    "$(bsc_name "$wts/gone")" "$(bsc_name "$wts/gone-too")" \
    "$(bsc_name "$main-sibling")" "$(bsc_name "$tmp/elsewhere")"
touch "$(bsc_name "$wts/stray-file")"
ln -s "$tmp/elsewhere" "$(bsc_name "$wts/link")"

check "stale caches: unreadable layout" "$(stale_build_server_caches "$bsc")" ''
read_worktree_layout "$main" || fail "stale caches: layout unreadable from $main"
check "stale caches: from the primary" "$(stale_build_server_caches "$bsc")" \
    "$(printf '%s\n' "$(bsc_name "$wts/gone")" "$(bsc_name "$wts/gone-too")")"
read_worktree_layout "$wts/live" || fail "stale caches: layout unreadable from live"
check "stale caches: from a linked worktree" "$(stale_build_server_caches "$bsc")" \
    "$(printf '%s\n' "$(bsc_name "$wts/gone")" "$(bsc_name "$wts/gone-too")")"
check "stale caches: no cache root" "$(stale_build_server_caches "$tmp/no-such-root")" ''

# ---- abandoned worktrees -----------------------------------------------------------

# expect_abandoned <name> <checkout> [<dir>...] — read from <checkout>, exactly
# these worktrees read as abandoned.
expect_abandoned() {
    local name=$1 checkout=$2
    shift 2
    if ! read_worktree_layout "$checkout"; then
        fail "$name: layout unreadable from $checkout"
        return
    fi
    abandoned_worktrees "$checkout"
    check "$name" "$(printf '%s\n' ${abandoned[@]+"${abandoned[@]}"})" "$(printf '%s\n' "$@")"
}

# commit_file <dir> <file> <content> — commit one file change in <dir>.
commit_file() {
    printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$2"
}

# The lock reason Claude Code writes, for <pid> started at <start>.
claude_lock() { printf 'claude agent %s (pid %s start %s)' "$1" "$2" "$3"; }

# A lock's start time in the form Claude Code writes: C locale, UTC.
lock_time() { LC_ALL=C date -u -r "$1" "+${2:-%a %b %d %T %Y}"; }

# The lock owner: a child whose start second is known without asking ps — the
# fork happened between two clock reads that agree.
while :; do
    t0=$(date +%s)
    sleep 600 &
    owner=$!
    children+=("$owner")
    [ "$(date +%s)" = "$t0" ] && break
done
owner_start=$(lock_time "$t0")

sleep 0 &
dead_pid=$!
wait "$dead_pid"

ab="$tmp/abandon"
abw="$ab/.claude/worktrees"
new_checkout "$ab"
commit_file "$ab" base.txt base

# Squash-merged: the branch's two commits land on main as one, so the branch is
# no ancestor of main while its content is.
git -C "$ab" worktree add -q -b worktree-squashed "$abw/squashed"
commit_file "$abw/squashed" a.txt a
commit_file "$abw/squashed" b.txt b
git -C "$ab" checkout -q main
printf 'a\n' >"$ab/a.txt"
printf 'b\n' >"$ab/b.txt"
git -C "$ab" add a.txt b.txt
git -C "$ab" commit -q -m 'squash'

# Squash-merged, then main edits the same line again: merging the branch into
# today's main conflicts, into the squash commit changes nothing.
git -C "$ab" worktree add -q -b worktree-edited-after "$abw/edited-after" main~1
commit_file "$abw/edited-after" base.txt v2
# Forked at the same point, and never on main in any commit.
git -C "$ab" worktree add -q -b worktree-diverged "$abw/diverged" main~1
commit_file "$abw/diverged" base.txt mine
commit_file "$ab" base.txt v2
commit_file "$ab" base.txt v3

git -C "$ab" update-ref "$default_ref" main

git -C "$ab" worktree add -q --detach "$abw/detached"

git -C "$ab" worktree add -q -b worktree-stale-lock "$abw/stale-lock"
git -C "$ab" worktree lock --reason "$(claude_lock stale-lock "$dead_pid" "$owner_start")" "$abw/stale-lock"

# Same pid, another start time: the pid was reused.
reused_reason=$(claude_lock reused-pid "$owner" 'Thu Jan 1 00:00:00 1970')
git -C "$ab" worktree add -q -b worktree-reused-pid "$abw/reused-pid"
git -C "$ab" worktree lock --reason "$reused_reason" "$abw/reused-pid"

# Kept as a branch once the worktree is gone: only worktree-* is deleted.
git -C "$ab" worktree add -q -b feature-kept "$abw/feature"

# Content never on main, but the commit itself is on an origin branch (an open
# PR's head); one commit past its push, it is not.
git -C "$ab" worktree add -q -b worktree-pushed "$abw/pushed"
commit_file "$abw/pushed" pushed.txt pushed
git -C "$ab" update-ref refs/remotes/origin/feat/pushed worktree-pushed
git -C "$ab" worktree add -q -b worktree-pushed-ahead "$abw/pushed-ahead" worktree-pushed
commit_file "$abw/pushed-ahead" ahead.txt ahead

# Content never on main nor on an origin branch, but in a pull request's head,
# which the remote keeps after the PR's branch is gone: the commit itself, with a
# review commit after it; the same patch picked onto another base; the same
# message with a revised patch; and a picked patch merged with the PR holding it,
# whose merge no PR holds. A PR head this clone never fetched is skipped.
origin="$tmp/origin.git"
git init -q --bare "$origin"
git -C "$ab" remote add origin "$origin"
# pull_head <N> <commit> — <commit> as PR #<N>'s head on the fixture remote.
pull_head() { git -C "$ab" push -q "$origin" "$2:refs/pull/$1/head"; }
# picked <commit> <onto> — <commit>'s patch committed onto <onto>.
picked() {
    local tree
    tree=$(git -C "$ab" merge-tree --write-tree --merge-base="$1~1" "$2" "$1") || return 1
    git -C "$ab" commit-tree -p "$2" -m picked "$tree"
}
git -C "$ab" worktree add -q -b worktree-pr-head "$abw/pr-head"
commit_file "$abw/pr-head" pr-head.txt one
pull_head 7 "$(git -C "$ab" commit-tree -p worktree-pr-head -m review 'worktree-pr-head^{tree}')"
git -C "$ab" worktree add -q -b worktree-pr-patch "$abw/pr-patch"
commit_file "$abw/pr-patch" pr-patch.txt one
pull_head 8 "$(picked worktree-pr-patch main~1)"
git -C "$ab" worktree add -q -b worktree-pr-revised "$abw/pr-revised"
commit_file "$abw/pr-revised" revised.txt first
pull_head 9 worktree-pr-revised
printf 'second\n' >"$abw/pr-revised/revised.txt"
git -C "$abw/pr-revised" commit -q -a --amend --no-edit
git -C "$ab" worktree add -q -b worktree-pr-merge "$abw/pr-merge"
commit_file "$abw/pr-merge" pr-merge.txt one
pr_merge_pick=$(picked worktree-pr-merge main~1)
pull_head 10 "$pr_merge_pick"
git -C "$abw/pr-merge" merge -q --no-ff -m merge "$pr_merge_pick"
elsewhere="$tmp/elsewhere"
new_checkout "$elsewhere"
commit_file "$elsewhere" elsewhere.txt elsewhere
git -C "$elsewhere" push -q "$origin" main:refs/pull/11/head

git -C "$ab" worktree add -q --detach "$abw/live-lock"
git -C "$ab" worktree lock --reason "$(claude_lock live-lock "$owner" "$owner_start")" "$abw/live-lock"
# ps pads a single-digit day; the comparison must not depend on the spacing.
git -C "$ab" worktree add -q --detach "$abw/live-lock-spaced"
git -C "$ab" worktree lock --reason "$(claude_lock live-lock-spaced "$owner" "$(lock_time "$t0" '%a  %b  %e  %T  %Y')")" "$abw/live-lock-spaced"
# A live owner whose start does not parse is not known to be gone.
git -C "$ab" worktree add -q --detach "$abw/unparsed-start"
git -C "$ab" worktree lock --reason "$(claude_lock unparsed-start "$owner" 'sometime')" "$abw/unparsed-start"

# Abandoned, but a process works inside it.
git -C "$ab" worktree add -q --detach "$abw/held"
(cd "$abw/held" && exec sleep 600) &
holder=$!
children+=("$holder")

# Otherwise abandoned, but a Claude Code session runs inside it without having
# locked it. The process name is what identifies a session, so the fixture runs
# a re-signed copy of sleep named `claude`.
git -C "$ab" worktree add -q --detach "$abw/session"
mkdir -p "$tmp/bin"
cp /bin/sleep "$tmp/bin/claude"
codesign -f -s - "$tmp/bin/claude" 2>/dev/null
(cd "$abw/session" && exec "$tmp/bin/claude" 600) &
session=$!
children+=("$session")
# A `claude` process with only a file open inside a worktree does not run in it.
git -C "$ab" worktree add -q --detach "$abw/open-file"
(cd "$tmp" && exec "$tmp/bin/claude" 600 <"$abw/open-file/base.txt") &
children+=("$!")

git -C "$ab" worktree add -q --detach "$abw/other-lock"
git -C "$ab" worktree lock --reason 'claude agent' "$abw/other-lock"
git -C "$ab" worktree add -q --detach "$abw/bare-lock"
git -C "$ab" worktree lock "$abw/bare-lock"

git -C "$ab" worktree add -q --detach "$abw/dirty"
printf 'changed\n' >"$abw/dirty/base.txt"
git -C "$ab" worktree add -q --detach "$abw/staged"
printf 'new\n' >"$abw/staged/new.txt"
git -C "$abw/staged" add new.txt
# The config is the repository's, so every worktree here hides untracked files
# from a plain `git status`.
git -C "$ab" config status.showUntrackedFiles no
git -C "$ab" worktree add -q --detach "$abw/untracked"
printf 'new\n' >"$abw/untracked/new.txt"
git -C "$ab" worktree add -q -b worktree-unmerged "$abw/unmerged"
commit_file "$abw/unmerged" c.txt c
git -C "$ab" worktree add -q -b worktree-conflict "$abw/conflict"
commit_file "$abw/conflict" base.txt other

# Edits `git status` cannot see: behind skip-worktree, behind assume-unchanged,
# and outside a sparse checkout's cone.
git -C "$ab" worktree add -q --detach "$abw/skip-worktree"
git -C "$abw/skip-worktree" update-index --skip-worktree base.txt
printf 'hidden\n' >"$abw/skip-worktree/base.txt"
git -C "$ab" worktree add -q --detach "$abw/assume-unchanged"
git -C "$abw/assume-unchanged" update-index --assume-unchanged base.txt
printf 'hidden\n' >"$abw/assume-unchanged/base.txt"
git -C "$ab" worktree add -q --detach "$abw/sparse"
git -C "$abw/sparse" sparse-checkout set --no-cone /a.txt

# The same, with an index listing well past a pipe buffer (64 KB) and the
# flagged entry first, where a consumer that stops at the first match leaves
# the rest of the listing unread.
big="$tmp/big"
new_checkout "$big"
mkdir -p "$big/tree"
seq -f "$big/tree/file-%06g-with-a-long-enough-name" 1 3000 | xargs touch
touch "$big/a-first"
git -C "$big" add -A
git -C "$big" commit -q -m files
git -C "$big" worktree add -q --detach "$big/.claude/worktrees/w"
git -C "$big/.claude/worktrees/w" update-index --skip-worktree a-first
printf 'hidden\n' >"$big/.claude/worktrees/w/a-first"
big_listing=$(git -C "$big/.claude/worktrees/w" ls-files -v)
if [ "${#big_listing}" -gt 65536 ] && [ "${big_listing%%$'\n'*}" = 'S a-first' ]; then
    pass
else
    fail "large index: the listing is not over 64 KB with the flagged entry first, so this case tests nothing"
fi
if worktree_unhidden "$big/.claude/worktrees/w"; then fail "large index: a hidden edit reads as none"; else pass; fi

git -C "$ab" worktree add -q --detach "$tmp/outside"
# Registered, with its directory gone (an unmounted volume, say): removing some
# other worktree must leave its registration alone.
git -C "$ab" worktree add -q --detach "$tmp/vanished"
rm -rf "$tmp/vanished"
mkdir -p "$abw/nested"
git -C "$ab" worktree add -q --detach "$abw/nested/deeper"

# An ignored build product is no uncommitted work.
git -C "$ab" worktree add -q --detach "$abw/ignored"
printf 'DerivedData/\n' >>"$ab/.git/info/exclude"
mkdir -p "$abw/ignored/DerivedData"
touch "$abw/ignored/DerivedData/product"

live_reason=$(claude_lock x "$owner" "$owner_start")
if claude_lock_stale "$live_reason"; then fail "live lock reads stale"; else pass; fi
# ps prints lstart in the caller's locale; the owner must still read live.
if [ "$(LC_ALL=de_DE.UTF-8 ps -o lstart= -p "$owner")" = "$(LC_ALL=C ps -o lstart= -p "$owner")" ]; then
    fail "de_DE: ps prints the C form, so this case tests nothing"
fi
# stale_in_locale <variable> <locale> <reason> — claude_lock_stale with only
# <variable> of the locale variables set in the environment.
stale_in_locale() {
    (
        unset LC_ALL LC_TIME LANG
        export "$1=$2"
        claude_lock_stale "$3"
    )
}
if stale_in_locale LC_ALL de_DE.UTF-8 "$live_reason"; then
    fail "live lock reads stale under LC_ALL=de_DE.UTF-8"
else
    pass
fi
if stale_in_locale LC_TIME en_GB.UTF-8 "$live_reason"; then
    fail "live lock reads stale under LC_TIME=en_GB.UTF-8"
else
    pass
fi
# …and ps's time is still read there, rather than failing to parse into a keep.
if stale_in_locale LC_ALL de_DE.UTF-8 "$(claude_lock x "$owner" 'Thu Jan 1 00:00:00 1970')"; then
    pass
else
    fail "reused pid reads live under LC_ALL=de_DE.UTF-8"
fi
if claude_lock_stale "$(claude_lock x "$owner" 'sometime')"; then fail "live pid, unparseable start reads stale"; else pass; fi
if claude_lock_stale "$(claude_lock x "$dead_pid" "$owner_start")"; then pass; else fail "stale lock: an exited pid reads live"; fi
if claude_lock_stale "$reused_reason"; then pass; else fail "reused pid reads live"; fi
# A process that started before the lock's owner cannot be a reuse of its pid.
if claude_lock_stale "$(claude_lock x "$owner" "$(lock_time $((t0 + 3600)))")"; then
    fail "pid started before the lock's owner reads stale"
else
    pass
fi
if claude_lock_stale 'claude session x (pid 1 start sometime) trailing'; then fail "malformed lock reads stale"; else pass; fi

if git -C "$ab" merge-tree --write-tree "$default_ref" worktree-edited-after >/dev/null 2>&1; then
    fail "edited after: merging into today's main does not conflict, so this case tests nothing"
else
    pass
fi

abandoned_set=("$abw/detached" "$abw/edited-after" "$abw/feature" "$abw/held" "$abw/ignored" "$abw/open-file" "$abw/pr-head" "$abw/pr-patch" "$abw/pushed" "$abw/reused-pid" "$abw/squashed" "$abw/stale-lock")
expect_abandoned "abandoned, from the primary" "$ab" "${abandoned_set[@]}"
expect_abandoned "abandoned, from a linked worktree" "$abw/dirty" "${abandoned_set[@]}"
# The checkout the layout is read from is never abandoned: removing it would
# delete the script reading it.
expect_abandoned "abandoned, from an abandoned worktree" "$abw/detached" \
    "$abw/edited-after" "$abw/feature" "$abw/held" "$abw/ignored" "$abw/open-file" "$abw/pr-head" "$abw/pr-patch" "$abw/pushed" "$abw/reused-pid" "$abw/squashed" "$abw/stale-lock"

# A default_ref that does not resolve vouches for no content: what stays
# abandoned is what an origin branch or PR head holds — feat/pushed descends
# from main, so it holds edited-after's patch as main's own commit.
git -C "$ab" update-ref -d "$default_ref"
expect_abandoned "no origin/main" "$ab" \
    "$abw/detached" "$abw/edited-after" "$abw/feature" "$abw/held" "$abw/ignored" "$abw/open-file" "$abw/pr-head" "$abw/pr-patch" "$abw/pushed" "$abw/reused-pid" "$abw/stale-lock"


# The fixture's Trash: dispose moves a worktree here, keeping everything in it.
fixture_trash="$tmp/Trash"
mkdir -p "$fixture_trash"
to_fixture_trash() { mv "$1" "$fixture_trash/"; }
leave_in_place() { :; }
always_held() { printf 'PID 1 (fixture)\n'; }

# section_output <command>... — a report section's lines, one marker word each.
# Run in a subshell so its helpers do not replace this file's pass/fail
# counters.
section_output() {
    # shellcheck disable=SC2329 # called by the section command "$@" runs
    (
        pass() { printf 'pass: %s\n' "$1"; }
        warn() { printf 'warn: %s\n' "$1"; }
        ghost() { printf 'ghost: %s\n' "$1"; }
        fixed() { printf 'fixed: %s\n' "$1"; }
        detail() { printf 'detail: %s\n' "$1"; }
        pretty_path() { printf '%s' "$1"; }
        disk_size() { printf '1K'; }
        "$@"
    )
}

# report_output <fix> [<holders>] — the abandoned-worktree section's lines.
report_output() {
    section_output report_abandoned_worktrees "$ab" "$1" "${2:-holder_blocked_lines}" to_fixture_trash
}
skipped='warn: Skipped the abandoned-worktree check: origin/main does not resolve'
check "no origin/main: report" "$(report_output 0)" "$skipped"
read_worktree_layout "$ab"
before=$worktree_paths
check "no origin/main: repair" "$(report_output 1)" "$skipped"
read_worktree_layout "$ab"
check "no origin/main: repair removed nothing" "$worktree_paths" "$before"

git -C "$ab" update-ref "$default_ref" main
report=$(report_output 0)
check "with origin/main: report" "$(printf '%s\n' "$report" | sed -n '1p')" \
    "ghost: Abandoned worktree (clean, content on origin/main): $abw/detached — 1K"
check "pushed: report" "$(printf '%s\n' "$report" | grep -F "$abw/pushed")" \
    "ghost: Abandoned worktree (clean, HEAD on origin/feat/pushed): $abw/pushed — 1K"
check "in a PR head: report" "$(printf '%s\n' "$report" | grep -F "$abw/pr-head")" \
    "ghost: Abandoned worktree (clean, HEAD on PR #7): $abw/pr-head — 1K"
check "patch in a PR head: report" "$(printf '%s\n' "$report" | grep -F "$abw/pr-patch")" \
    "ghost: Abandoned worktree (clean, patches on PR #8): $abw/pr-patch — 1K"

# The process working in `held` is named, and the worktree is not removable.
check "in use: report" "$(printf '%s\n' "$report" | grep -A2 -F "$abw/held")" \
    "ghost: Abandoned worktree, but in use: $abw/held — 1K
detail: holding it open: PID $holder (sleep)
detail: quit it (or reboot), then re-run"
read_worktree_layout "$ab"
if remove_abandoned_worktree "$ab" "$ab" "$abw/held" holder_blocked_lines to_fixture_trash; then fail "in use: removed"; else pass; fi
if [ -d "$abw/held" ]; then pass; else fail "in use: directory gone"; fi

# A worktree a session runs inside is not reported at all, nor removable.
check "session: report" "$(printf '%s\n' "$report" | grep -cF "$abw/session")" 0
read_worktree_layout "$ab"
if remove_abandoned_worktree "$ab" "$ab" "$abw/session" holder_blocked_lines to_fixture_trash; then fail "session: removed"; else pass; fi
if [ -d "$abw/session" ]; then pass; else fail "session: directory gone"; fi

# A holders command that claims every worktree keeps every worktree, even in
# repair mode.
read_worktree_layout "$ab"
before=$worktree_paths
held_report=$(report_output 1 always_held)
check "all held: nothing reported removable" \
    "$(printf '%s\n' "$held_report" | grep -c '^ghost: Abandoned worktree, but in use: ')" "${#abandoned_set[@]}"
check "all held: nothing fixed" "$(printf '%s\n' "$held_report" | grep -c '^fixed:')" 0
read_worktree_layout "$ab"
check "all held: nothing removed" "$worktree_paths" "$before"

# expect_removed <name> <worktree> — removal succeeds, and the directory is in
# the fixture Trash and no longer registered.
expect_removed() {
    read_worktree_layout "$ab"
    if remove_abandoned_worktree "$ab" "$ab" "$2" holder_blocked_lines to_fixture_trash; then pass; else fail "$1: removal refused"; fi
    if [ -e "$2" ]; then fail "$1: directory survived"; else pass; fi
    if [ -d "$fixture_trash/${2##*/}" ]; then pass; else fail "$1: not in the Trash"; fi
    if worktree_registered "$2"; then fail "$1: still registered"; else pass; fi
}

expect_removed "squash-merged" "$abw/squashed"
if git -C "$ab" rev-parse -q --verify refs/heads/worktree-squashed >/dev/null; then
    pass
else
    fail "squash-merged: the worktree pass deleted its branch"
fi
expect_removed "detached at main" "$abw/detached"
expect_removed "stale claude lock" "$abw/stale-lock"
expect_removed "squash-merged, then edited on main" "$abw/edited-after"
expect_removed "non-worktree branch" "$abw/feature"
expect_removed "pushed" "$abw/pushed"
expect_removed "in a PR head" "$abw/pr-head"
expect_removed "patch in a PR head" "$abw/pr-patch"
# Ignored files travel with the directory rather than being deleted.
expect_removed "ignored files" "$abw/ignored"
if [ -f "$fixture_trash/ignored/DerivedData/product" ]; then pass; else fail "ignored files: lost"; fi

# A stale lock lifted for an attempt that leaves the directory is put back.
read_worktree_layout "$ab"
if remove_abandoned_worktree "$ab" "$ab" "$abw/reused-pid" holder_blocked_lines leave_in_place; then
    fail "dispose failed: reported removed"
else
    pass
fi
check "dispose failed: lock restored" "$(worktree_field "$abw/reused-pid" locked)" "$reused_reason"

# Work that appears between the report and the repair keeps the worktree.
printf 'late\n' >"$abw/reused-pid/late.txt"
read_worktree_layout "$ab"
if remove_abandoned_worktree "$ab" "$ab" "$abw/reused-pid" holder_blocked_lines to_fixture_trash; then fail "late work: removed"; else pass; fi
if [ -d "$abw/reused-pid" ]; then pass; else fail "late work: directory gone"; fi
check "late work: lock kept" "$(worktree_field "$abw/reused-pid" locked)" "$reused_reason"

# An unlisted path is refused outright.
read_worktree_layout "$ab"
if remove_abandoned_worktree "$ab" "$ab" "$tmp/outside" holder_blocked_lines to_fixture_trash; then fail "outside: removed"; else pass; fi
if [ -d "$tmp/outside" ]; then pass; else fail "outside: directory gone"; fi

expect_abandoned "after removal" "$ab" "$abw/held" "$abw/open-file"

# ---- orphaned worktree branches ----------------------------------------------------

# The removed worktrees' worktree-* branches are orphaned once their work is on
# the remote. Not orphaned: a branch a registered worktree has checked out
# (worktree-reused-pid, …), any other name (feature-kept), and one whose work
# the remote does not hold (worktree-unheld, the never-merged diverged commit).
git -C "$ab" branch worktree-unheld worktree-diverged
orphan_set=(refs/heads/worktree-edited-after refs/heads/worktree-pr-head refs/heads/worktree-pr-patch refs/heads/worktree-pushed refs/heads/worktree-squashed refs/heads/worktree-stale-lock)
read_worktree_layout "$ab"
orphaned_worktree_branches
check "orphaned branches" "$(printf '%s\n' ${orphaned_branches[@]+"${orphaned_branches[@]}"})" "$(printf '%s\n' "${orphan_set[@]}")"

git -C "$ab" update-ref -d "$default_ref"
check "orphaned branches, no origin/main" "$(section_output report_orphaned_branches "$ab" 1)" \
    'warn: Skipped the orphaned-branch check: origin/main does not resolve'
git -C "$ab" update-ref "$default_ref" main

branch_report=$(section_output report_orphaned_branches "$ab" 0)
check "orphaned branch: report" "$(printf '%s\n' "$branch_report" | grep -F ': worktree-squashed')" \
    'ghost: Orphaned worktree branch (content on origin/main): worktree-squashed'
check "orphaned branch in a PR head: report" "$(printf '%s\n' "$branch_report" | grep -F ': worktree-pr-head')" \
    'ghost: Orphaned worktree branch (HEAD on PR #7): worktree-pr-head'

# Deleted only while it is still unchecked-out and still at the tip that was judged.
read_worktree_layout "$ab"
if delete_orphaned_branch "$ab" refs/heads/worktree-squashed "$(git -C "$ab" rev-parse main)"; then
    fail "moved branch: deleted"
else
    pass
fi
if delete_orphaned_branch "$ab" refs/heads/worktree-reused-pid "$(git -C "$ab" rev-parse worktree-reused-pid)"; then
    fail "checked-out branch: deleted"
else
    pass
fi

# The upstream `git push -u` records goes with the branch, so a later branch of
# the same name does not inherit it.
git -C "$ab" config branch.worktree-squashed.remote origin
git -C "$ab" config branch.worktree-squashed.merge refs/heads/feat/squashed
check "orphaned branches: repair" "$(section_output report_orphaned_branches "$ab" 1 | grep -c '^fixed: deleted branch ')" "${#orphan_set[@]}"
check "orphaned branches: left" "$(git -C "$ab" for-each-ref --format='%(refname)' refs/heads/feature-kept refs/heads/worktree-reused-pid refs/heads/worktree-unheld refs/heads/worktree-squashed)" \
    "refs/heads/feature-kept
refs/heads/worktree-reused-pid
refs/heads/worktree-unheld"
check "orphaned branch: config" "$(git -C "$ab" config --get-regexp '^branch\.worktree-squashed\.')" ''
check "orphaned branches: after repair" "$(section_output report_orphaned_branches "$ab" 0)" 'pass: No orphaned worktree-* branches'

# ---- holders ---------------------------------------------------------------------

# A process outside this test's tree whose arguments name the target — a path
# inside it, or the target itself as a whole argument — holds it; one naming a
# longer sibling (`<target>-bar`) does not, and neither does the asking shell,
# whose own arguments name the target both ways.
argv_target="$tmp/argv-target"
mkdir -p "$argv_target"
# argv_holder <argument> — one process, detached from this shell by the
# subshell exiting, whose arguments end with <argument>; `tail -f` keeps
# following /dev/null after reporting the missing path.
argv_holder() {
    (tail -f /dev/null "$1" >/dev/null 2>&1 &
        echo $! >"$tmp/argv-pid")
    cat "$tmp/argv-pid"
}
inside_pid=$(argv_holder "$argv_target/inside")
whole_pid=$(argv_holder "$argv_target")
sibling_pid=$(argv_holder "$argv_target-bar")
children+=("$inside_pid" "$whole_pid" "$sibling_pid")
check "argv holders" "$(ROOT=$ROOT bash -c '. "$ROOT/Tools/lib/holders.sh"; refresh_holders "$1"; path_holders "$1"' \
    asker "$argv_target" "$argv_target/self")" \
    "$(printf '%s\ttail\topen\n' "$inside_pid" "$whole_pid" | sort -n)"

# Nor does a shell that invoked the asker about the target (`make clean`, a
# wrapper `zsh -c '…; ls <arena>'`): an ancestor's arguments name the target
# because it ran the asker about it. The trailing `:` keeps the outer shell
# alive as the asker's parent instead of exec-ing into it.
check "argv holders: invoking ancestor" "$(ROOT=$ROOT bash -c 'bash -c "$2" asker "$1"; :' outer "$argv_target" \
    '. "$ROOT/Tools/lib/holders.sh"; refresh_holders "$1"; path_holders "$1"')" \
    "$(printf '%s\ttail\topen\n' "$inside_pid" "$whole_pid" | sort -n)"

# An ancestor outside the asker's job — an editor or interactive shell that
# started it as a job of its own — still holds the target its arguments name.
# `set -m` gives the background asker its own process group; `set +m` before
# the wait keeps its job notice off stderr.
jobs_out=$(ROOT=$ROOT bash -c 'echo $$ >"$3"; set -m; bash -c "$2" asker "$1" & set +m; wait $!; :' outer "$argv_target" \
    '. "$ROOT/Tools/lib/holders.sh"; refresh_holders "$1"; path_holders "$1"' "$tmp/outer-pid")
check "argv holders: ancestor in another job" "$jobs_out" \
    "$({ printf '%s\ttail\topen\n' "$inside_pid" "$whole_pid"; printf '%s\tbash\topen\n' "$(cat "$tmp/outer-pid")"; } | sort -n)"

# Each removal deleted only its own record: the vanished worktree, a candidate
# for any repository-wide prune, is still registered.
if git -C "$ab" worktree list --porcelain | grep -qxF "worktree $tmp/vanished"; then
    pass
else
    fail "vanished: an unrelated registration was pruned"
fi

# A layout that cannot be re-read stops the removal before it touches anything.
remove_abandoned_worktree "$tmp/not-a-checkout" "$ab" "$abw/held" always_held to_fixture_trash
check "unreadable layout: status" "$?" 3
remove_abandoned_worktree '' "$ab" "$abw/held" always_held to_fixture_trash
check "no checkout: status" "$?" 3

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s worktrees: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
