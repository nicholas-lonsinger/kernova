#!/usr/bin/env bash
# The Linux half of the dead-code scan: KernovaKit as SwiftPM builds it for
# Linux, where the Linux agent's sources compile, its tests included — on Linux
# with the `swift` on PATH, and on a Mac cross-built with the Ubuntu SDK (`make
# ubuntu-sdk`). Replaces <output-dir> with the platform bundle the combined
# report reads — full.json, production.json and presence.tsv — and prints the
# Linux-only report.
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
# shellcheck source=lib/linux-swift.sh
. "$root/Tools/lib/linux-swift.sh"

scratch="$root/KernovaKit/.build/dead-code-linux"
build=(--scratch-path "$scratch" --build-tests --enable-index-store)
if [ "$(uname -s)" = Darwin ]; then
    version="$(pinned_swift_version)"
    missing="$(ubuntu_sdk_missing "$version")"
    if [ -n "$missing" ]; then
        printf 'dead-code-linux.sh: %s is not installed: run `make ubuntu-sdk`\n' "$missing" >&2
        exit 1
    fi
    build+=(--swift-sdk "$(ubuntu_sdk_id "$version")")
fi

mkdir -p "$(dirname "$2")"
output="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
periphery="$("$root/Tools/install-periphery.sh")"
indexutil="$("$root/Tools/install-periphery.sh" --indexutil-export)"
swift build -c release --quiet --package-path "$root/Tools/DeadCode" >&2
tool="$root/Tools/DeadCode/.build/release/dead-code"

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT
linux_swift build "${build[@]}" >&2
store="$(linux_swift build "${build[@]}" --show-bin-path)/index/store"
linux_swift package --scratch-path "$scratch" describe --type json >"$raw/package.json"

"$tool" bundle --root "$root" --base "$root/KernovaKit" --periphery "$periphery" --store "$store" \
    --indexutil-export "$indexutil" --test-only-targets "$1" --package-description "$raw/package.json" \
    --output "$output"
"$tool" report --platform linux="$output"
