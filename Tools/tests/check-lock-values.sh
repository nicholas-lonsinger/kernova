#!/usr/bin/env bash
# Fixture tests for the lock-values rule (Tools/swift-rules/lock-values.pm):
# which lock-box type arguments it flags, and on which line.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_rule() { bash "$ROOT/Tools/check-swift-sources.sh" --rule lock-values "$@"; }

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source_file='KernovaKit/Sources/KernovaAgentRuntime/Fixture.swift'
test_file='KernovaKit/Tests/KernovaKitTests/Fixture.swift'

# expect <name> <path> <want> <swift source> — the check, run over a file at
# <path> relative to a scratch repository root holding the source, flags
# exactly the lines in <want> (space-separated, empty for a pass).
expect() {
    local name=$1 path=$2 want=$3 dir="$tmp/$1" output status got
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$4" >"$dir/$path"
    output=$(cd "$dir" && run_rule "$path" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-lock-values: $path:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

# Stored directly.

expect bare-function "$source_file" '1 2' 'let a = Locked<@Sendable () -> Void>({})
let b = Mutex<(Int) -> Int>({ $0 })'
expect optional-function "$source_file" '1 2 3' 'let a = Locked<(@Sendable () -> Void)?>(nil)
private static let b = Mutex<(@Sendable (URLRequest) -> StubResponse)?>(nil)
let c = Locked<Optional<() -> Void>>(nil)'
expect tuple-element "$source_file" '1 2' 'let a = Locked<(queue: DispatchQueue, handler: @Sendable () -> Void)>(pair)
let b = Locked<(Int, (() -> Void)?)>((0, nil))'
expect parameter-and-annotation "$source_file" '1 2' 'func install(into box: Locked<(() -> Void)?>) {}
let box: Mutex<() async throws -> Void> = make()'
expect spans-lines "$source_file" '1' 'let a = Locked<
    (@Sendable (Result<Data, WireError>) -> Void)?
>(nil)'
expect test-code "$test_file" '1' 'let a = Locked<(() -> Void)?>(nil)'

# Held where its depth stays put.

expect collections "$source_file" '' 'let a = Locked<[UUID: @Sendable () -> Void]>([:])
let b = Locked<[@Sendable (Result<any ByteStream, DialFailure>) -> Void]>([])
let c = Locked<[Int: [@Sendable () -> Void]]>([:])
let d = Locked<[(queue: DispatchQueue, handler: @Sendable (HostEvent) -> Void)]>([])
let e = Locked<(ended: Bool, handlers: [@Sendable () -> Void], filePulls: Int)>((false, [], 0))
let f = Mutex<Array<() -> Void>>([])'
expect struct-field "$source_file" '' 'struct Wake: Sendable { let post: @Sendable () -> Void }
let a = Locked<Wake?>(nil)
let b = Locked(State())'
expect plain-values "$source_file" '' 'let a = Locked<UInt64>(0)
let b = Mutex<[Record]>([])
let c = Locked<(Int, String)?>(nil)
func mechanism(calls: Locked<Int>) -> MacPowerMechanism { make() }
let d: (Locked<Int>) -> Void = { _ in }'
expect prose-and-strings "$source_file" '' '// Never Locked<() -> Void>; wrap it.
let text = "Mutex<(() -> Void)?>"
/* Locked<(Int) -> Int> */'
expect other-generics "$source_file" '' 'let a = Box<() -> Void>({})
let b = registry.Locked<() -> Void>({})'

# An unreadable file fails.

output=$(cd "$tmp" && run_rule "$source_file" 2>&1)
status=$?
if [ "$status" -eq 0 ] || [[ $output != *"cannot read $source_file"* ]]; then
    fail "missing-file: exited $status without naming the unread file"
fi

if [ "$FAIL" -gt 0 ]; then
    printf '%d check-lock-values fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'check-lock-values fixtures: all passed\n'
