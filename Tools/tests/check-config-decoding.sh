#!/usr/bin/env bash
# Fixture tests for Tools/check-config-decoding.sh: which spellings of a
# decodeIfPresent fallback it flags, and on which line.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-config-decoding.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect <name> <want> <swift source> — the check, run over a file holding the
# source, reports exactly the lines in <want> (space-separated, empty for a
# pass).
expect() {
    local name=$1 want=$2 file="$tmp/$1.swift" output status got
    printf '%s\n' "$3" >"$file"
    output=$(bash "$check_script" "$file" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-config-decoding: $file:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

expect one-line 2 'let c = try decoder.container(keyedBy: CodingKeys.self)
self.a = try c.decodeIfPresent(Bool.self, forKey: .a) ?? false'

expect operator-on-next-line 1 'guestAgents: try c.decodeIfPresent(Set<VMGuestAgentBucket>.self, forKey: .guestAgents)
    ?? [],'

expect arguments-across-lines 1 'self.b = try c.decodeIfPresent(
    String.self,
    forKey: .b) ?? ""'

expect parenthesised-try 1 'self.c = (try? c.decodeIfPresent(Int.self, forKey: .c)) ?? 0'

expect nested-call-in-arguments 1 'self.d = try c.decodeIfPresent(type(of: x), forKey: .d) ?? x'

expect two-on-two-lines '1 2' 'a = try c.decodeIfPresent(A.self, forKey: .a) ?? .one
b = try c.decodeIfPresent(B.self, forKey: .b) ?? .two'

expect bare-optional '' 'self.e = try c.decodeIfPresent(Data.self, forKey: .e)
self.f = g ?? h'

expect fallback-on-a-later-expression '' 'self.e = try c.decodeIfPresent(Data.self, forKey: .e)
let f = g ?? h'

expect comment '' '// Not `decodeIfPresent(T.self, forKey: k) ?? d`: the check cannot repair it.
self.a = try c.decode(Bool.self, forKey: .a, default: defaults.a, in: decoder)'

if [ "$FAIL" -gt 0 ]; then
    printf 'check-config-decoding fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-config-decoding fixtures: all passed\n'
