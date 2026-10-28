#!/usr/bin/env bash
# Checks two builds of `kernova-agent` from one commit, as the Linux CI job
# makes them from two checkout paths: each is an agent Kernova can bundle
# (check_linux_agent, which every build already runs), and the two are
# byte-identical.
#
# Usage: Tools/check-linux-guest-agent.sh <binary> <binary>

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"
# shellcheck source=lib/linux-agent.sh
. "$lib_dir/lib/linux-agent.sh"

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <binary> <binary>" >&2
    exit 2
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

failed=0
check_linux_agent "$1" || failed=1
check_linux_agent "$2" || failed=1
first="$(sha256 "$1")"
second="$(sha256 "$2")"
if [ "$first" != "$second" ]; then
    echo "check-linux-guest-agent: the two builds differ: $first and $second" >&2
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1
pass "kernova-agent: two checkout paths build the same agent"
value "sha256 $first"
