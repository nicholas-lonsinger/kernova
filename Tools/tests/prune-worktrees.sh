#!/usr/bin/env bash
# Fixture test for Tools/prune-worktrees.sh, in a clone whose origin
# squash-merged two branches, one after a later commit, and then edited the
# lines they changed: every worktree holding uncommitted or unmerged work, or
# a lock a live process or a person holds, stays; the merged ones and those
# whose lock a dead session left go; and -n changes nothing. Local git only;
# fakes stand in for GitHub and Launch Services.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf '  %s✗%s %s: got %s, wanted %s\n' "$c_red" "$c_reset" "$1" "$2" "$3"; fi
}

# Resolved, as git reports worktree paths: TMPDIR on macOS is under /var, a
# symlink.
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/prune-worktrees.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES=$tmp
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$tmp/bin"
printf '#!/bin/sh\n' >"$tmp/bin/lsregister"
# Every search finds pull request 7, a merged one whose commits are listed in
# $tmp/pr-commits.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    'pr list') echo 7 ;;
    'pr view') cat '$tmp/pr-commits' ;;
esac
EOF
chmod +x "$tmp/bin/lsregister" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

main=$tmp/main
wts=$main/.claude/worktrees
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$main"
git -C "$main" remote add origin "$tmp/origin.git"
commit() { # <checkout> <file> <content> [<message>]
    printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "${4:-$3}"
}
commit "$main" file a
mkdir -p "$main/Tools/lib"
cp "$ROOT/Tools/prune-worktrees.sh" "$main/Tools/"
cp "$ROOT/Tools/lib/worktrees.sh" "$main/Tools/lib/"
add() { git -C "$main" worktree add -q -b "$1" "$wts/$1" main; }
lock() { git -C "$main" worktree lock --reason "$2" "$wts/$1"; }

add merged && commit "$wts/merged" file b
add carried-on && commit "$wts/carried-on" other draft
git -C "$wts/carried-on" rev-parse HEAD >"$tmp/pr-commits"
add unmerged && commit "$wts/unmerged" file x
add untracked && touch "$wts/untracked/new"
add modified && printf 'z\n' >"$wts/modified/file"
add hidden && git -C "$wts/hidden" update-index --skip-worktree file && printf 'z\n' >"$wts/hidden/file"
add unlocked

sleep 0 &
dead=$!
wait "$dead"
live_start=$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ | awk '{ $1 = $1; print }')
add live && lock live "claude agent live (pid $$ start $live_start)"
add live-no-start && lock live-no-start "claude session live-no-start (pid $$)"
add by-hand && lock by-hand 'on an external drive'
add dead && lock dead "claude agent dead (pid $dead start $live_start)"
add dead-no-start && lock dead-no-start "claude session dead-no-start (pid $dead)"
add reused-pid && lock reused-pid "claude agent reused-pid (pid $$ start Thu Jan  1 00:00:00 1970)"

# The squash merges, then later edits of the lines they changed.
commit "$main" file b 'Squash merge'
commit "$main" other final 'Squash merge of a branch that carried on'
commit "$main" file c
git -C "$main" push -q origin main

kept='by-hand hidden live live-no-start modified unmerged untracked'
removed='carried-on dead dead-no-start merged reused-pid unlocked'
# listed <verb> <output> — the worktrees <output> names after <verb>.
listed() { sed -n "s/^$1 \([^ :]*\).*/\1/p" <<<"$2" | sort | paste -sd ' ' -; }

out=$(bash "$main/Tools/prune-worktrees.sh" -n 2>&1)
check '-n: removes' "$(listed 'would remove' "$out")" "$removed"
check '-n: keeps' "$(listed keep "$out")" "$kept"
for wt in $kept $removed; do
    check "-n leaves $wt" "$(git -C "$main" worktree list | grep -c "/$wt ")" 1
done

out=$(bash "$main/Tools/prune-worktrees.sh" 2>&1)
check 'removes' "$(listed remove "$out")" "$removed"
check 'keeps' "$(listed keep "$out")" "$kept"
for wt in $kept; do
    check "$wt is kept" "$([ -d "$wts/$wt" ] && git -C "$main" rev-parse -q --verify "refs/heads/$wt" >/dev/null && echo yes)" yes
done
for wt in $removed; do
    check "$wt is removed" "$([ -e "$wts/$wt" ] || git -C "$main" rev-parse -q --verify "refs/heads/$wt" >/dev/null || echo yes)" yes
done
check 'git lists only the kept' "$(git -C "$main" worktree list --porcelain | sed -n 's|^worktree .*/||p' | sed 1d | sort | paste -sd ' ' -)" "$kept"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s prune-worktrees: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
