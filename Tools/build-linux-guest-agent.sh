#!/usr/bin/env bash
# Builds `kernova-agent`, the static aarch64 Linux guest agent, with the
# swift.org toolchain .swift-version pins and its Static Linux SDK, and copies
# it, mode 0644, to where it is wanted. It downloads nothing.
#
# Usage:
#   Tools/build-linux-guest-agent.sh
#     as the app target's "Build Linux Guest Agent" phase: labels the agent
#     "<MARKETING_VERSION> (<build number>)" and writes
#     $TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/GuestAgents/linux-arm64/kernova-agent
#   Tools/build-linux-guest-agent.sh --output <file> [--label <label>]
#     anywhere else, as the Linux CI job runs it; the label defaults to
#     "development"
#
# On macOS the toolchain is swiftly's (`make swift-toolchain` installs it),
# run with the environment scrubbed so Xcode's SDKROOT, TOOLCHAINS and
# DEVELOPER_DIR cannot reach it. On Linux it is the `swift` on PATH, which the
# CI container pins.
#
# Two builds of one commit are byte-identical from any checkout path: the
# prefix maps take the checkout's path out of every string the compilers
# embed, and stripping takes out the rest of the debug info.
#
# KERNOVA_LINUX_AGENT_FAULT=hang-before-hello (a Debug-only build setting)
# builds an agent that never dials, for the update rollback gate.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/static-linux-sdk.sh
. "$repo/Tools/lib/static-linux-sdk.sh"

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
    : "${TARGET_BUILD_DIR:?run from Xcode, or pass --output}"
    output="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/GuestAgents/linux-arm64/kernova-agent"
    build_number="$(awk '/KERNOVA_BUILD_NUMBER/ { print $3 }' "$DERIVED_FILE_DIR/KernovaBuildNumber.h")"
    label="$MARKETING_VERSION ($build_number)"
fi
label="${label:-development}"

swift_version="$(tr -d '[:space:]' <"$repo/.swift-version")"
sdk_id="swift-${swift_version}-RELEASE_static-linux-${STATIC_SDK_VERSION}"
missing() {
    echo "error: $1 is not installed: run \`make swift-toolchain\`" >&2
    exit 1
}

if [ "$(uname -s)" = Darwin ]; then
    swiftly="${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/bin/swiftly"
    [ -x "$swiftly" ] || missing swiftly
    [ -d "$HOME/Library/Developer/Toolchains/swift-${swift_version}-RELEASE.xctoolchain" ] \
        || missing "Swift $swift_version"
    [ -d "$HOME/Library/org.swift.swiftpm/swift-sdks/${sdk_id}.artifactbundle" ] || missing "$sdk_id"
    swift=(env -i "HOME=$HOME" PATH=/usr/bin:/bin)
    [ -z "${SWIFTLY_HOME_DIR:-}" ] || swift+=("SWIFTLY_HOME_DIR=$SWIFTLY_HOME_DIR")
    swift+=("$swiftly" run swift build "+$swift_version")
else
    swift sdk list | grep -qxF "$sdk_id" || missing "$sdk_id"
    swift=(swift build)
fi

flags=(
    --package-path "$repo/KernovaKit" --scratch-path "$repo/KernovaKit/.build/swiftly"
    --swift-sdk aarch64-swift-linux-musl -c release --product kernova-agent
    -Xswiftc -file-prefix-map -Xswiftc "$repo=."
    -Xswiftc -Xfrontend -Xswiftc -disable-incremental-llvm-codegen
    -Xcc "-ffile-prefix-map=$repo=."
    -Xlinker --strip-all
)

case "${KERNOVA_LINUX_AGENT_FAULT:-}" in
    '') ;;
    hang-before-hello)
        if [ "${CONFIGURATION:-}" = Release ]; then
            echo "error: KERNOVA_LINUX_AGENT_FAULT is set in a Release build" >&2
            exit 1
        fi
        flags+=(-Xswiftc -DKERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO)
        ;;
    *) echo "error: KERNOVA_LINUX_AGENT_FAULT=$KERNOVA_LINUX_AGENT_FAULT is not a fault this build knows" >&2; exit 1 ;;
esac

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

mkdir -p "$(dirname "$output")"
if ! cmp -s "$built" "$output"; then
    cp "$built" "$output"
fi
chmod 0644 "$output"
