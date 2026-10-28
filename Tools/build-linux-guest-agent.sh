#!/usr/bin/env bash
# Builds `kernova-agent`, the static aarch64 Linux guest agent, with the
# swift.org toolchain .swift-version pins and its Static Linux SDK, checks it
# is an agent Kernova can bundle, and copies it, mode 0644, to where it is
# wanted. The toolchain and SDK must already be installed (`make
# swift-toolchain`); the only thing it may fetch is the swift-protobuf source at
# the pinned revision, on a first build that SwiftPM's shared cache cannot
# serve.
#
# Usage:
#   Tools/build-linux-guest-agent.sh
#     as the KernovaLinuxGuestAgent target's "Build Linux Guest Agent" phase:
#     labels the agent "<MARKETING_VERSION> (<build number>)" and writes the
#     phase's one declared output
#   Tools/build-linux-guest-agent.sh --output <file> [--label <label>]
#     anywhere else, as the Linux CI job runs it; the label defaults to
#     "development"
#
# On macOS the toolchain is swiftly's, run with the environment scrubbed so
# Xcode's SDKROOT, TOOLCHAINS and DEVELOPER_DIR cannot reach it. On Linux it is
# the `swift` on PATH, which the CI container pins.
#
# The agent's dependencies resolve only to the versions the project's tracked
# Package.resolved pins, the file Xcode builds the host against, so the agent
# and the host link one swift-protobuf.
#
# Two builds of one commit are byte-identical from any checkout path: the
# prefix maps take the checkout's path out of every string the compilers
# embed, the frontend embeds no IR hash, and stripping takes out the rest of
# the debug info.
#
# KERNOVA_LINUX_AGENT_FAULT=hang-before-hello builds an agent that never dials,
# for the update rollback gate, and only in a Debug build.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/static-linux-sdk.sh
. "$repo/Tools/lib/static-linux-sdk.sh"
# shellcheck source=lib/linux-agent.sh
. "$repo/Tools/lib/linux-agent.sh"

output=''
label=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        *) echo "usage: $0 [--output <file> [--label <label>]]" >&2; exit 2 ;;
    esac
done

if [ -z "$output" ]; then
    output="${SCRIPT_OUTPUT_FILE_0:?run from Xcode, or pass --output}"
    build_number="$(awk '/KERNOVA_BUILD_NUMBER/ { print $3 }' "$DERIVED_FILE_DIR/KernovaBuildNumber.h")"
    label="$MARKETING_VERSION ($build_number)"
fi
label="${label:-development}"

swift_version="$(tr -d '[:space:]' <"$repo/.swift-version")"
missing="$(swift_toolchain_missing "$swift_version")"
if [ -n "$missing" ]; then
    echo "error: $missing is not installed: run \`make swift-toolchain\`" >&2
    exit 1
fi

if [ "$(uname -s)" = Darwin ]; then
    swift=(env -i "HOME=$HOME" PATH=/usr/bin:/bin)
    [ -z "${SWIFTLY_HOME_DIR:-}" ] || swift+=("SWIFTLY_HOME_DIR=$SWIFTLY_HOME_DIR")
    swift+=("$(swiftly_binary)" run swift build "+$swift_version")
else
    swift=(swift build)
fi

flags=(
    --package-path "$repo/KernovaKit" --scratch-path "$repo/KernovaKit/.build/swiftly"
    --only-use-versions-from-resolved-file
    --swift-sdk "$(static_sdk_id "$swift_version")" --triple aarch64-swift-linux-musl
    -c release --product kernova-agent
    -Xswiftc -file-prefix-map -Xswiftc "$repo=."
    -Xswiftc -Xfrontend -Xswiftc -disable-incremental-llvm-codegen
    -Xcc "-ffile-prefix-map=$repo=."
    -Xlinker --strip-all
)

case "${KERNOVA_LINUX_AGENT_FAULT:-}" in
    '') ;;
    hang-before-hello)
        if [ -n "${CONFIGURATION:-}" ] && [ "$CONFIGURATION" != Debug ]; then
            echo "error: KERNOVA_LINUX_AGENT_FAULT is set in a $CONFIGURATION build; only Debug builds carry it" >&2
            exit 1
        fi
        flags+=(-Xswiftc -DKERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO)
        ;;
    *) echo "error: KERNOVA_LINUX_AGENT_FAULT=$KERNOVA_LINUX_AGENT_FAULT is not a fault this build knows" >&2; exit 1 ;;
esac

# SwiftPM reads a package's pins from beside its manifest, so the tracked pin
# is copied there; rewritten only when it changes, so nothing re-resolves.
pin="$repo/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cmp -s "$pin" "$repo/KernovaKit/Package.resolved" || cp "$pin" "$repo/KernovaKit/Package.resolved"

# The label reaches one C file through a header on the include path: a -D flag
# would change every compile command and rebuild every module whenever the
# build number moves. Rewritten only when it changes, so an unchanged label
# rebuilds nothing.
label_dir="$repo/KernovaKit/.build/swiftly/agent-version"
mkdir -p "$label_dir"
escaped="${label//\\/\\\\}"
escaped="${escaped//\"/\\\"}"
header="#define KERNOVA_AGENT_VERSION_LABEL \"$escaped\""
if [ "$(cat "$label_dir/KernovaAgentVersionLabel.h" 2>/dev/null)" != "$header" ]; then
    printf '%s\n' "$header" >"$label_dir/KernovaAgentVersionLabel.h"
fi
flags+=(-Xcc "-I$label_dir")

"${swift[@]}" "${flags[@]}"
built="$("${swift[@]}" "${flags[@]}" --show-bin-path)/kernova-agent"
check_linux_agent "$built"

mkdir -p "$(dirname "$output")"
if ! cmp -s "$built" "$output"; then
    cp "$built" "$output"
fi
chmod 0644 "$output"
