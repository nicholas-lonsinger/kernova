#!/usr/bin/env bash
# Fixture tests for Tools/check-swift-sources.sh run the way lint runs it, with
# no arguments: which rule each finding is reported under, which files each
# rule's scope reads, and which rules print their pass line. Each rule's own
# findings are its fixture suite's.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-swift-sources.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# A file two rules flag, a test file only the test-waits rule reads, and the
# one file the config-decoding rule's scope leaves out.
repo="$tmp/repo"
mkdir -p "$repo/App" "$repo/AppTests" "$repo/KernovaKit/Sources/KernovaCommandModel"
printf '%s\n' 'print(x)' 'let a = Locked<() -> Void>({})' 'Thread.sleep(forTimeInterval: 1)' >"$repo/App/A.swift"
printf '%s\n' 'Thread.sleep(forTimeInterval: 1)' >"$repo/AppTests/B.swift"
printf '%s\n' 'self.a = try c.decodeIfPresent(Bool.self, forKey: .a) ?? false' >"$repo/KernovaKit/Sources/KernovaCommandModel/ConfigFileDecoding.swift"
git init -q "$repo"
git -C "$repo" add .

(cd "$repo" && bash "$check_script") >"$tmp/out" 2>"$tmp/err"
status=$?

got=$(sed -n 's|^\(check-[a-z-]*: [^ ]*\) — .*|\1|p' "$tmp/err" | sort | tr '\n' ' ')
want='check-lock-values: App/A.swift:2 check-logging: App/A.swift:1 check-test-waits: AppTests/B.swift:1 '
[ "$got" = "$want" ] || fail "findings: got '$got', wanted '$want': $(cat "$tmp/err")"

got=$(sed -n 's|^  ✓ \([a-z ]*\):.*|\1|p' "$tmp/out" | tr '\n' ',')
[ "$got" = 'config decoding,exit tests,' ] || fail "pass lines: got '$got', wanted the two rules with no finding: $(cat "$tmp/out")"

[ "$status" -eq 1 ] || fail "exited $status with findings, wanted 1"

# A rule name with no rule behind it fails, naming it.
output=$(cd "$repo" && bash "$check_script" --rule lock-value 2>&1)
status=$?
if [ "$status" -eq 0 ] || [[ $output != *"no rule named lock-value"* ]]; then
    fail "unknown-rule: exited $status without naming it: $output"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'check-swift-sources fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-swift-sources fixtures: all passed\n'
