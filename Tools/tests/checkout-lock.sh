#!/usr/bin/env bash
# Fixture tests for Tools/checkout-lock.sh: a second run in one checkout waits
# and says so, the lock outlives neither its holder nor reaches the holder's
# descendants, and separate checkouts never wait on each other. Runs a copy of
# the script in a fixture clone and in a linked worktree of it; every wait is
# on a fifo or a process, never a sleep.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
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

clone="$tmp/clone"
wt="$tmp/wt"
git init -q -b main "$clone" && git -C "$clone" commit -q --allow-empty -m init
git -C "$clone" worktree add -q --detach "$wt"
for checkout in "$clone" "$wt"; do
    mkdir -p "$checkout/Tools"
    cp "$ROOT/Tools/checkout-lock.sh" "$checkout/Tools/"
done
lock_of() { git -C "$1" rev-parse --path-format=absolute --git-path xcodebuild.lock; }

# is_free <checkout> — the checkout's lock can be taken right now.
is_free() { /usr/bin/lockf -k -s -t 0 "$(lock_of "$1")" true; }

# hold <checkout> <name> — runs a locked command in <checkout> that writes its
# pid to the fifo <name>.ready once it holds the lock, then waits for a line
# on the fifo <name>.release and touches <name>.done. Sets $holder to the
# lock-holding process; returns once the command holds the lock.
hold() {
    local dir=$tmp/$2
    mkfifo "$dir.ready" "$dir.release"
    "$1/Tools/checkout-lock.sh" bash -c \
        'echo $$ >"$1.ready"; read -r _ <"$1.release"; touch "$1.done"' _ "$dir" &
    holder=$!
    children+=("$holder")
    read -r held_by <"$dir.ready"
}

# ---- a second run waits, says so, then runs ------------------------------------

hold "$clone" first
mkfifo "$tmp/second.err"
"$clone/Tools/checkout-lock.sh" bash -c '[ -e "$1/first.done" ] && touch "$1/second.ran"' _ "$tmp" \
    2>"$tmp/second.err" &
second=$!
children+=("$second")
exec 7<"$tmp/second.err"
read -r notice <&7
check "the waiting run's notice" "$notice" \
    "checkout-lock.sh: waiting for another xcodebuild in this checkout to finish ($(lock_of "$clone"))"
check "the waiting run has not run" "$([ -e "$tmp/second.ran" ] && echo ran || echo waiting)" waiting
echo >"$tmp/first.release"
wait "$holder"
check "the holder's status" "$?" 0
wait "$second"
check "the waiting run's status" "$?" 0
check "the waiting run ran after the holder" "$([ -e "$tmp/second.ran" ] && echo after || echo not)" after
check "the waiting run's stderr after its notice" "$(cat <&7)" ''
exec 7<&-

check "a free lock: no notice" "$("$clone/Tools/checkout-lock.sh" true 2>&1)" ''
"$clone/Tools/checkout-lock.sh" sh -c 'exit 3'
check "the command's exit status" "$?" 3

# ---- a killed holder releases, and its command ends with it --------------------

hold "$clone" killed
kill -TERM "$holder"
wait "$holder" 2>/dev/null
check "the killed holder's status" "$?" $((128 + 15))
check "the killed holder's command" "$(kill -0 "$held_by" 2>/dev/null && echo running || echo gone)" gone
check "the lock after its holder is killed" "$(is_free "$clone" && echo free || echo held)" free

# ---- a grandchild left running does not hold the lock --------------------------

mkfifo "$tmp/grandchild.pid" "$tmp/never"
"$clone/Tools/checkout-lock.sh" bash -c \
    'bash -c "read -r _ <\"\$1\"" _ "$1/never" </dev/null >/dev/null 2>&1 & echo $! >"$1/grandchild.pid"' _ "$tmp" &
locked=$!
children+=("$locked")
read -r grandchild <"$tmp/grandchild.pid"
children+=("$grandchild")
wait "$locked"
check "the grandchild outlives the locked command" \
    "$(kill -0 "$grandchild" 2>/dev/null && echo running || echo gone)" running
check "the lock while the grandchild runs" "$(is_free "$clone" && echo free || echo held)" free

# ---- separate checkouts never wait on each other -------------------------------

check "a worktree's lock is its own" "$([ "$(lock_of "$clone")" != "$(lock_of "$wt")" ] && echo own || echo shared)" own
hold "$clone" other
if is_free "$wt"; then
    check "the worktree's run while the clone is held" \
        "$("$wt/Tools/checkout-lock.sh" echo ran 2>&1)" ran
else
    fail "the worktree's lock is held while only the clone's is"
fi
echo >"$tmp/other.release"
wait "$holder"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s checkout-lock: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
