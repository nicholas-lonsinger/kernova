#!/usr/bin/env bash
# The Linux half of the dead-code scan: KernovaKit as SwiftPM builds it on
# Linux, where the Linux agent's sources compile, its tests included. Replaces
# <output-dir> with the platform bundle the combined report reads — full.json,
# production.json and presence.tsv — and prints the Linux-only report.
#
# The production view excludes the targets listed in <test-only-targets>, one
# per line, as `make dead-code-targets` prints them on macOS: what the app
# links shows only in the Xcode project and the macOS manifest.
#
# Usage: Tools/dead-code-linux.sh <test-only-targets> <output-dir>

set -euo pipefail

if [ $# -ne 2 ]; then
    printf 'Usage: Tools/dead-code-linux.sh <test-only-targets> <output-dir>\n' >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mapfile -t excluded <"$1"
if [ "${#excluded[@]}" -eq 0 ]; then
    printf 'dead-code-linux.sh: %s lists no target\n' "$1" >&2
    exit 1
fi
mkdir -p "$(dirname "$2")"
output="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"

periphery="$("$root/Tools/install-periphery.sh")"
indexutil="$("$root/Tools/install-periphery.sh" --indexutil-export)"
swift build -c release --quiet --package-path "$root/Tools/DeadCode" >&2
tool="$root/Tools/DeadCode/.build/release/dead-code"

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT
cd "$root/KernovaKit"
scan() {
    "$periphery" scan --config "$root/.periphery.yml" --disable-update-check --quiet --format json "$@"
}
scan -- --enable-index-store >"$raw/full.json"
scan --skip-build --exclude-targets "${excluded[@]}" >"$raw/production.json"

"$tool" bundle --root "$root" --base "$root/KernovaKit" \
    --full "$raw/full.json" --production "$raw/production.json" \
    --store "$root/KernovaKit/.build/debug/index/store" --indexutil-export "$indexutil" --output "$output"
"$tool" report --platform linux="$output"
