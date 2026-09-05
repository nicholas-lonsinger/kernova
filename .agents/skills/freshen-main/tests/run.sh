#!/usr/bin/env bash
# Fixture tests for the freshen-main skill: builds a bare "remote", a seeding
# clone that pushes to it, and a primary clone with a worktree, then drives
# freshen-main.sh from inside the worktree through every verdict. Local git
# only — no network — and it takes a few seconds. Run it after editing the
# skill.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$ROOT/.agents/skills/freshen-main/freshen-main.sh"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

# git reports worktree paths resolved, so resolve the fixture root the same way
# (on macOS mktemp answers under /var, a symlink to /private/var).
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# Pin everything git reads from the environment, so the run reports on the
# script and not on this machine's identity or global config.
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

git init -q --bare -b main "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/seed" 2>/dev/null
git -C "$tmp/seed" switch -q -c main 2>/dev/null || git -C "$tmp/seed" checkout -q -b main 2>/dev/null
seed_commit() { # <text>
    printf '%s\n' "$1" >"$tmp/seed/file"
    git -C "$tmp/seed" add file && git -C "$tmp/seed" commit -q -m "$1" && git -C "$tmp/seed" push -q origin main 2>/dev/null
}
seed_commit A
git clone -q "$tmp/remote.git" "$tmp/local" 2>/dev/null
git -C "$tmp/local" worktree add -q -b topic "$tmp/local/wt" 2>/dev/null
cd "$tmp/local/wt" || exit 1

# run <name> <expected-exit> <expected-verdict-regex> [args...]
run() {
    local name="$1" want_exit="$2" want="$3"; shift 3
    local out code
    out="$("$SCRIPT" "$@" 2>/dev/null)"; code=$?
    [ "$code" -eq "$want_exit" ] || fail "$name: exit $code, wanted $want_exit"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "$name: stdout is not exactly one line: $out"
    if printf '%s' "$out" | grep -qE "$want"; then pass; else fail "$name: got '$out', wanted /$want/"; fi
}
local_main() { git -C "$tmp/local" rev-parse main; }
remote_main() { git -C "$tmp/seed" rev-parse main; }

run "current" 0 '^freshen-main: verdict=current branch=main$'

seed_commit B
run "fast-forwarded" 0 "^freshen-main: verdict=fast-forwarded branch=main path=$tmp/local\$"
if [ "$(local_main)" = "$(remote_main)" ]; then pass; else fail "fast-forwarded: local main is not at the remote tip"; fi

seed_commit C
printf 'local edit\n' >"$tmp/local/file"
run "dirty" 0 "^freshen-main: verdict=dirty branch=main path=$tmp/local\$"
if [ "$(local_main)" != "$(remote_main)" ]; then pass; else fail "dirty: the branch moved despite local changes"; fi
git -C "$tmp/local" checkout -q -- file
run "clean again" 0 '^freshen-main: verdict=fast-forwarded '

printf 'local commit\n' >"$tmp/local/file"
git -C "$tmp/local" commit -q -am "local D"
seed_commit E
run "diverged" 0 "^freshen-main: verdict=diverged branch=main path=$tmp/local\$"
git -C "$tmp/local" reset -q --hard origin/main

git -C "$tmp/local" checkout -q --detach
run "not-checked-out" 0 '^freshen-main: verdict=not-checked-out branch=main$'
git -C "$tmp/local" checkout -q main

run "bad remote" 1 '^freshen-main: verdict=setup-error reason=fetch-failed remote=nope$' --remote nope
run "bad argument" 1 '^freshen-main: verdict=setup-error reason=usage argument=--bogus$' --bogus
mkdir -p "$tmp/empty"; ( cd "$tmp/empty" && run "not a repository" 1 '^freshen-main: verdict=setup-error reason=not-a-repository$' )

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s freshen-main: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
