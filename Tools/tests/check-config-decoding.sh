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

expect map-then-fallback 1 'self.a = try c.decodeIfPresent(String.self, forKey: .a).map { $0.lowercased() } ?? ""'

expect map-across-lines-then-fallback 1 'self.a = try c.decodeIfPresent([String].self, forKey: .a)
    .map(Set.init)
    ?? []'

expect optional-chain-then-fallback 1 'self.a = try c.decodeIfPresent(Mode.self, forKey: .a)?.rawValue ?? 0'

expect try-optional-decode 1 'self.c = (try? c.decode(Int.self, forKey: .c)) ?? 0'

expect try-optional-decode-unparenthesised 1 'self.c = try? container.decode(Int.self, forKey: .c) ?? 0'

expect try-optional-whole-value '' 'let options = (try? JSONDecoder().decode(Options.self, from: data)) ?? Options()'

expect string-with-slashes-before 1 'let base = "http://x"; self.b = try c.decodeIfPresent(Bool.self, forKey: .b) ?? false'

expect block-comment '' '/* decodeIfPresent(A.self, forKey: .a) ?? x */
self.a = try c.decode(A.self, forKey: .a, default: .one, in: decoder)'

expect line-after-block-comment 4 '/*
  a decodeIfPresent(A.self, forKey: .a) ?? x, spread over lines
*/
self.a = try c.decodeIfPresent(A.self, forKey: .a) ?? .one'

expect close-paren-in-string-argument 1 'self.a = try c.decodeIfPresent(Bool.self, forKey: Key(stringValue: "a)b")!) ?? false'

expect quote-in-comment 2 '// a lone " in prose
self.a = try c.decodeIfPresent(Bool.self, forKey: .a) ?? false'

# A file the check cannot open fails it, rather than passing unread.
output=$(bash "$check_script" "$tmp/missing.swift" 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
    fail "unreadable-file: exited 0 for a file it could not open"
elif ! printf '%s\n' "$output" | grep -q "cannot read $tmp/missing.swift"; then
    fail "unreadable-file: no 'cannot read' line in: $output"
fi

# A relative argument names a file under the caller's working directory, not
# under the top level of the repository the caller is in.
mkdir -p "$tmp/repo/sub"
git init -q "$tmp/repo"
printf '%s\n' 'self.a = try c.decodeIfPresent(Bool.self, forKey: .a) ?? false' >"$tmp/repo/sub/Field.swift"
output=$(cd "$tmp/repo/sub" && bash "$check_script" Field.swift 2>&1)
status=$?
if [ "$status" -eq 0 ] || ! printf '%s\n' "$output" | grep -q '^check-config-decoding: Field.swift:1 '; then
    fail "relative-path: wanted Field.swift:1 flagged, got status $status: $output"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'check-config-decoding fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-config-decoding fixtures: all passed\n'
