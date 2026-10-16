#!/usr/bin/env bash
# Fixture tests for Tools/checkout-lock.sh: a second run in one checkout waits
# and says so, the lock outlives neither its holder nor reaches the holder's
# descendants, a descendant of the holder runs at once, separate checkouts
# never wait on each other, and Tools/lsp-config.sh and `make build` take the
# same lock. Runs copies of the scripts in a fixture clone and a linked
# worktree of it, with stub xcodebuild and xcode-build-server; every wait is on
# a fifo or a process, never a sleep, and ends if the process under test exits.

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
        wait 2>/dev/null
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
    mkdir -p "$checkout/Tools/lib"
    cp "$ROOT/Tools/checkout-lock.sh" "$ROOT/Tools/lsp-config.sh" "$checkout/Tools/"
    cp "$ROOT/Tools/lib/output.sh" "$checkout/Tools/lib/"
    cp "$ROOT/Makefile" "$checkout/"
done
lock_of() { git -C "$1" rev-parse --path-format=absolute --git-path xcodebuild.lock; }

# is_free <checkout> — the checkout's lock can be taken right now.
is_free() { /usr/bin/lockf -k -s -t 0 "$(lock_of "$1")" true; }

# hold <checkout> <name> — runs a locked command in <checkout> that holds the
# lock until a line arrives on the fifo <name>.release, then touches
# <name>.done. Returns once the command holds the lock, with $holder set to
# the lock-holding process and $held_by to the command; a holder that exits
# first ends the suite.
hold() {
    local dir=$tmp/$2 state
    mkfifo "$dir.events" "$dir.release"
    (
        "$1/Tools/checkout-lock.sh" bash -c \
            'echo "held $$ $PPID" >"$1.events"; read -r _ <"$1.release"; touch "$1.done"' _ "$dir" &
        wait "$!" 2>/dev/null
        echo "exited $?" >"$dir.events"
    ) &
    children+=("$!")
    read -r state held_by holder <"$tmp/$2.events"
    if [ "$state" != held ]; then
        fail "$2: the locked command exited ($held_by) without holding the lock"
        exit 1
    fi
    children+=("$holder" "$held_by")
}

# exit_status <name> — waits for <name>'s holder to exit; prints its status.
exit_status() {
    local state status
    read -r state status <"$tmp/$1.events"
    printf '%s' "$status"
}

notice_for() { printf 'checkout-lock.sh: waiting for another xcodebuild in this checkout to finish (%s)' "$(lock_of "$1")"; }

# ---- a second run waits, says so, then runs ------------------------------------

hold "$clone" first
mkfifo "$tmp/second.err"
# An inherited holder entry naming a live process that is not an ancestor
# lets nothing past the lock.
KERNOVA_CHECKOUT_LOCKS="$holder	$(lock_of "$clone")" \
    "$clone/Tools/checkout-lock.sh" bash -c '[ -e "$1/first.done" ] && touch "$1/second.ran"' _ "$tmp" \
    2>"$tmp/second.err" &
second=$!
children+=("$second")
exec 7<"$tmp/second.err"
read -r notice <&7
check "the waiting run's notice" "$notice" "$(notice_for "$clone")"
check "the waiting run has not run" "$([ -e "$tmp/second.ran" ] && echo ran || echo waiting)" waiting
echo >"$tmp/first.release"
check "the holder's status" "$(exit_status first)" 0
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
check "the killed holder's status" "$(exit_status killed)" $((128 + 15))
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
check "the grandchild's open lock descriptors" \
    "$(lsof -a -p "$grandchild" -Fn 2>/dev/null | grep -c 'xcodebuild\.lock$')" 0
check "the lock while the grandchild runs" "$(is_free "$clone" && echo free || echo held)" free
kill "$grandchild" 2>/dev/null

# ---- a descendant of the holder runs at once -----------------------------------

mkfifo "$tmp/nested.out"
"$clone/Tools/checkout-lock.sh" bash -c 'exec "$1/Tools/checkout-lock.sh" echo nested >"$2" 2>&1' \
    _ "$clone" "$tmp/nested.out" &
outer=$!
children+=("$outer")
read -r nested <"$tmp/nested.out"
check "a run nested in the holder" "$nested" nested
[ "$nested" = nested ] || kill -TERM "$outer"
wait "$outer" 2>/dev/null

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
check "the other holder's status" "$(exit_status other)" 0

# ---- lsp-config.sh and `make build` share the lock -----------------------------

stubs="$tmp/stubs"
mkdir -p "$stubs"
# xcode-build-server reports it is running, then holds until released.
cat >"$stubs/xcode-build-server" <<'EOF'
#!/bin/bash
echo "lsp $PPID" >"$FIXTURE/lsp.events"
read -r _ <"$FIXTURE/lsp.release"
touch "$FIXTURE/lsp.done"
EOF
# xcodebuild answers a settings query, and records whether a build ran after
# xcode-build-server finished.
cat >"$stubs/xcodebuild" <<'EOF'
#!/bin/bash
case " $* " in
    *' -showBuildSettings '*)
        printf 'Build settings for action build and target Kernova:\n    TARGET_BUILD_DIR = /b\n    EXECUTABLE_PATH = K\n'
        ;;
    *)
        if [ -e "$FIXTURE/lsp.done" ]; then echo after; else echo during; fi >"$FIXTURE/build.ran"
        ;;
esac
EOF
chmod +x "$stubs/xcode-build-server" "$stubs/xcodebuild"
mkfifo "$tmp/lsp.events" "$tmp/lsp.release" "$tmp/make.err"
export FIXTURE="$tmp"
export PATH="$stubs:$PATH"

(
    "$clone/Tools/lsp-config.sh" >/dev/null
    echo "exited $?" >"$tmp/lsp.events"
) &
children+=("$!")
read -r state lsp_holder <"$tmp/lsp.events"
check "lsp-config.sh's xcode-build-server" "$state" lsp
children+=("$lsp_holder")
CI=1 make -C "$clone" --no-print-directory build >/dev/null 2>"$tmp/make.err" &
make_pid=$!
children+=("$make_pid")
exec 7<"$tmp/make.err"
make_notice=''
while read -r line <&7; do
    case "$line" in *'waiting for another xcodebuild'*) make_notice=$line; break ;; esac
done
check "make build's notice while lsp-config.sh holds the lock" "$make_notice" "$(notice_for "$clone")"
check "make build's xcodebuild while lsp-config.sh holds the lock" "$(cat "$tmp/build.ran" 2>/dev/null)" ''
echo >"$tmp/lsp.release"
check "lsp-config.sh's status" "$(exit_status lsp)" 0
wait "$make_pid"
check "make build's status" "$?" 0
check "make build's xcodebuild" "$(cat "$tmp/build.ran" 2>/dev/null)" after
exec 7<&-

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s checkout-lock: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
