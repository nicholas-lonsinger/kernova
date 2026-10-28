#!/usr/bin/env bash
# Fixture tests for Tools/check-core-imports.sh's hub check: every blocking
# form and every spelling of the main actor fails, and prose in a comment and
# the async forms pass.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-core-imports.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect <name> <want> <swift source> — the check, run over a file holding the
# source, flags exactly the lines in <want> (space-separated, empty for a pass).
expect() {
    local name=$1 want=$2 file="$tmp/$1.swift" output status got
    printf '%s\n' "$3" >"$file"
    output=$(bash "$check_script" --hub-files "$file" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^  $file:\([0-9]*\): .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

expect async-hops '' 'queue.async { work() }
DispatchQueue.main.async { publish() }'
expect prose-in-a-comment '' '// Never queue.sync { }, never @MainActor, never semaphore.wait().
let x = 1  // DispatchSemaphore would block'
expect a-name-holding-sync '' 'let synced = isSynchronized'

expect trailing-closure-sync '1' 'queue.sync { work() }'
expect parenthesised-sync '1' 'queue.sync(execute: work)'
expect sync-with-flags '1' 'queue.sync(flags: .barrier) { work() }'
expect async-and-wait '1' 'queue.asyncAndWait { work() }'
expect semaphore '1 2' 'let semaphore = DispatchSemaphore(value: 0)
semaphore.wait()'
expect group-wait '1' 'group.wait(timeout: .now() + 1)'
expect main-actor-attribute '1' '@MainActor func publish() {}'
expect main-actor-run '1' 'await MainActor.run { publish() }'
expect main-actor-assume '1' 'MainActor.assumeIsolated { publish() }'
expect after-code-on-a-line '2' 'let a = 1
let b = queue.sync { 2 }  // the code before the comment is still read'

if [ "$FAIL" -gt 0 ]; then
    printf '%d check-core-imports hub fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'check-core-imports hub fixtures: all passed\n'
