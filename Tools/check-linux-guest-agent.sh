#!/usr/bin/env bash
# Checks two builds of `kernova-agent` from one commit, as the Linux CI job
# makes them from two checkout paths: each is a statically linked aarch64
# ELF under the size budget with no ICU data in it, and the two are
# byte-identical.
#
# ICU is what an unconditional `import Foundation` can pull into a static
# binary: tens of megabytes of locale data, whose table of contents names
# every item `icudt<version>…`. The binary is stripped, so the check reads
# its bytes rather than its symbols.
#
# Usage: Tools/check-linux-guest-agent.sh <binary> <binary>

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# About a third over the agent's size, room for what later features add;
# ICU alone would take it past.
budget=$((16 * 1024 * 1024))

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <binary> <binary>" >&2
    exit 2
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

failed=0
for binary in "$@"; do
    description="$(file -b "$binary")"
    case "$description" in
        *"ELF 64-bit LSB"*"ARM aarch64"*"statically linked"*) ;;
        *) echo "check-linux-guest-agent: $binary is not a static aarch64 ELF: $description" >&2; failed=1 ;;
    esac
    size="$(wc -c <"$binary" | tr -d '[:space:]')"
    if [ "$size" -gt "$budget" ]; then
        echo "check-linux-guest-agent: $binary is $size bytes, over the $budget-byte budget" >&2
        failed=1
    fi
    icu="$(LC_ALL=C grep -ac icudt "$binary")"
    if [ "$icu" -ne 0 ]; then
        echo "check-linux-guest-agent: $binary carries ICU data ($icu lines name icudt)" >&2
        failed=1
    fi
done

first="$(sha256 "$1")"
second="$(sha256 "$2")"
if [ "$first" != "$second" ]; then
    echo "check-linux-guest-agent: the two builds differ: $first and $second" >&2
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1
pass "kernova-agent: static aarch64 ELF, $size bytes, no ICU, reproducible"
value "sha256 $first"
