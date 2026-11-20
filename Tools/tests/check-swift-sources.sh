#!/usr/bin/env bash
# Fixture tests for Tools/check-swift-sources.sh run the way lint runs it, with
# no arguments: which rule each finding is reported under, which files each
# rule's scope reads, and which rules print their pass line. Then what fails
# the check outright: a file that does not parse, a rule module that is no
# rule, and a malformed command line. Each rule's own findings are its fixture
# suite's.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-swift-sources.sh"
# shellcheck source=../lib/dead-code-tool.sh
. "$ROOT/Tools/lib/dead-code-tool.sh"
dead_code_sources=$(installed_dead_code_sources) || exit 1

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

# A file that does not parse fails every rule that reads it, naming where it
# stops; a rule whose scope leaves it out still passes.
unparsed="$tmp/unparsed"
mkdir -p "$unparsed/App" "$unparsed/AppTests"
printf '%s\n' 'let a = 1' 'let s = "never closed' >"$unparsed/App/D.swift"
printf '%s\n' 'let b = 2' >"$unparsed/AppTests/E.swift"
git init -q "$unparsed"
git -C "$unparsed" add .
(cd "$unparsed" && bash "$check_script" --rule lock-values --rule test-waits) >"$tmp/out" 2>"$tmp/err"
status=$?
[ "$status" -eq 1 ] || fail "unparsed: exited $status, wanted 1"
grep -q '^check-swift-sources: App/D.swift:2:[0-9]* does not parse as Swift$' "$tmp/err" ||
    fail "unparsed: no line naming where App/D.swift stops parsing: $(cat "$tmp/err")"
got=$(sed -n 's|^  ✓ \([a-z ]*\):.*|\1|p' "$tmp/out" | tr '\n' ',')
[ "$got" = 'test waits,' ] || fail "unparsed: pass lines '$got', wanted only the rule that does not read App/D.swift"

# usage_error <name> <want on stderr> <argument>... — the check exits 2 having
# printed exactly the one line.
usage_error() {
    local name=$1 want=$2 status err
    shift 2
    (cd "$repo" && bash "$check_script" --tool "$dead_code_sources" "$@") >/dev/null 2>"$tmp/err"
    status=$?
    err=$(cat "$tmp/err")
    if [ "$status" -ne 2 ] || [ "$err" != "$want" ]; then
        fail "$name: exited $status with '$err', wanted 2 with '$want'"
    fi
}
usage_error unknown-rule \
    'check-swift-sources: no rule named lock-value; the rules are config-decoding exit-tests lock-values logging test-waits' \
    --rule lock-value
usage_error rule-without-a-name 'usage: Tools/check-swift-sources.sh [--tool <path>] [--rule <name>]... [<file>...]' --rule
usage_error unknown-option 'usage: Tools/check-swift-sources.sh [--tool <path>] [--rule <name>]... [<file>...]' --rules x

# A tracked rule module that returns no check, or no pass line, fails the
# check before any file is read: here no file is in any rule's scope.
tools="$tmp/tools"
mkdir -p "$tools/Tools/lib" "$tools/Tools/swift-rules" "$tools/Tools/DeadCode"
cp "$check_script" "$tools/Tools/"
for lib in output.sh dead-code-tool.sh package-pins.sh; do cp "$ROOT/Tools/lib/$lib" "$tools/Tools/lib/"; done
git init -q "$tools"
mkdir -p "$tmp/empty"
git init -q "$tmp/empty"
for broken in "check:+{ pass => 'x' }" "pass line:+{ check => sub { () } }"; do
    printf '%s\n' "${broken#*:}" >"$tools/Tools/swift-rules/broken.pm"
    git -C "$tools" add -A
    output=$(cd "$tmp/empty" && bash "$tools/Tools/check-swift-sources.sh" --tool "$dead_code_sources" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] || [[ $output != *"broken.pm: its rule has no ${broken%%:*}"* ]]; then
        fail "a rule with no ${broken%%:*}: exited $status: $output"
    fi
done

if [ "$FAIL" -gt 0 ]; then
    printf 'check-swift-sources fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-swift-sources fixtures: all passed\n'
