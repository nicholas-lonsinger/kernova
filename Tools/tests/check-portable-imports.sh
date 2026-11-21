#!/usr/bin/env bash
# Fixture tests for Tools/check-portable-imports.sh: every spelling of a
# Foundation-module import fails, and only the FoundationEssentials-first form
# passes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-portable-imports.sh"

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
    output=$(bash "$check_script" --files "$file" 2>&1)
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

guarded='#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif'

expect guarded-form '' "$guarded"
expect guarded-form-among-other-imports '' "import KernovaDBus
$guarded
import Testing"
expect prose-in-a-comment '' '// A portable target never writes import Foundation on its own.
let x = 1  // import FoundationNetworking would link ICU'
expect a-module-named-like-foundation '' 'import KernovaFoundationTools'

expect bare-foundation '1' 'import Foundation'
expect bare-essentials '1' 'import FoundationEssentials'
expect internal-import '1' 'internal import Foundation'
expect public-import '1' 'public import Foundation'
expect package-international '1' 'package import FoundationInternationalization'
expect private-international '1' 'private import FoundationInternationalization'
expect spi-attribute '1' '@_spi(Internal) import Foundation'
expect preconcurrency '1' '@preconcurrency import Foundation'
expect exported-declaration '1' '@_exported import struct Foundation.Data'
expect submodule '1' 'import Foundation.NSString'
expect networking '1' 'import FoundationNetworking'
expect xml '1' 'import FoundationXML'
expect trailing-semicolon '1' 'import Foundation;'
expect international-after-the-form '6' "$guarded
import FoundationInternationalization"
expect modifier-in-the-fallback '2 4' '#if canImport(FoundationEssentials)
import FoundationEssentials
#else
internal import Foundation
#endif'
expect fallback-without-endif '2 4' '#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation'
expect other-condition '2' '#if canImport(Darwin)
import Foundation
#endif'

if [ "$FAIL" -gt 0 ]; then
    printf 'check-portable-imports fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-portable-imports fixtures: all passed\n'
