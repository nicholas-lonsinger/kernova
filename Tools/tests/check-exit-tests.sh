#!/usr/bin/env bash
# Fixture tests for Tools/check-exit-tests.sh: which exit tests outside the
# exit-test target, and which tests inside it, it flags, and on which line.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-exit-tests.sh"
exit_root='KernovaKit/Tests/KernovaKitExitTests'

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# expect <name> <path> <want> <swift source> — the check, run in a repository
# whose one tracked file is <path> holding the source, reports exactly the
# lines in <want> (space-separated, empty for a pass).
expect() {
    local name=$1 path=$2 want=$3 repo="$tmp/$1" output status got
    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$4" >"$repo/$path"
    git init -q "$repo"
    git -C "$repo" add .
    output=$(cd "$repo" && bash "$check_script" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-exit-tests: $path:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want': $output"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status: $output"
    fi
}

# Outside the exit-test target.

expect outside-expect KernovaKit/Tests/KernovaKitTests/A.swift 3 'struct A {
    @Test func traps() async {
        await #expect(processExitsWith: .failure) { fatalError() }
    }
}'

expect outside-require KernovaCore/Tests/KernovaCoreTests/B.swift 2 'let x = 1
let exit = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {}'

expect outside-across-lines KernovaKit/Tests/KernovaKitTests/C.swift 2 'await #expect(
    processExitsWith: .failure
) {}'

expect outside-sibling-directory KernovaKit/Tests/KernovaKitExitTestsMore/D.swift 1 'await #expect(processExitsWith: .failure) {}'

expect outside-ordinary-test KernovaKit/Tests/KernovaKitTests/E.swift '' '@Test func adds() { #expect(1 + 1 == 2) }'

expect outside-comment KernovaKit/Tests/KernovaKitTests/F.swift '' '// #expect(processExitsWith: .failure) belongs in the exit-test target.
/* processExitsWith */
let x = 1'

expect outside-string KernovaKit/Tests/KernovaKitTests/G.swift '' 'let s = "processExitsWith"'

# Inside the exit-test target.

expect inside-exit-tests "$exit_root/H.swift" '' '@Suite(.caseScoped)
struct H {
    @Test("traps", arguments: [1, 2])
    func traps(_ value: Int) async throws {
        let shape = Shape(a: { 1 }())
        await #expect(processExitsWith: .failure) { fatalError("\(value)") }
    }

    @Test func requires() async throws {
        _ = try #require(await #require(processExitsWith: .success) {})
    }
}'

expect inside-ordinary-test "$exit_root/I.swift" 2 'struct I {
    @Test func adds() { #expect(1 + 1 == 2) }

    @Test("traps") func traps() async {
        await #expect(processExitsWith: .failure) {}
    }
}'

expect inside-exit-test-named-only-in-a-comment "$exit_root/J.swift" 1 '@Test("an exit test") func adds() {
    // #expect(processExitsWith: .failure)
    #expect(true)
}'

expect inside-attribute-across-lines "$exit_root/K.swift" 1 '@Test(
    "adds",
    arguments: [1]
)
func adds(_ value: Int) {
    #expect(value == 1)
}'

expect inside-helper "$exit_root/L.swift" '' 'enum Shape { case one }
func emit() {}'

# A file the check cannot open fails it, rather than passing unread.
repo="$tmp/unreadable"
mkdir -p "$repo"
printf '%s\n' 'let x = 1' >"$repo/M.swift"
git init -q "$repo"
git -C "$repo" add .
rm "$repo/M.swift"
output=$(cd "$repo" && bash "$check_script" 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
    fail "unreadable-file: exited 0 for a file it could not open"
elif ! printf '%s\n' "$output" | grep -q 'cannot read M.swift'; then
    fail "unreadable-file: no 'cannot read' line in: $output"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'check-exit-tests fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-exit-tests fixtures: all passed\n'
