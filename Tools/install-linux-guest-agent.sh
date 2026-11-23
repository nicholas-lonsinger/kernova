#!/usr/bin/env bash
# Builds `kernova-agent`, the static aarch64 Linux guest agent, into the
# machine's tool cache (Tools/lib/tool-cache.sh) once per set of inputs, and
# prints its path. The cached agent carries the label "development";
# Tools/build-linux-guest-agent.sh labels a copy. A build cross-builds with
# the swift.org toolchain .swift-version pins and its Static Linux SDK, which
# must already be installed (`make swift-toolchain`); the only thing it may
# fetch is the swift-protobuf source at the pinned revision, on a first build
# that SwiftPM's shared cache cannot serve.
#
# Usage: Tools/install-linux-guest-agent.sh [--path]
#   --path  print the agent's path, building nothing
#
# Beside what tool_dir hashes for every entry, the entry's name hashes files,
# read from disk so an uncommitted or untracked edit is built, so finding an
# entry needs no swift.org toolchain: the directory of each of agent_targets,
# the package's manifest and the tracked pins; this script and the libraries it
# sources, one of which pins the SDK; .swift-version, which pins the
# toolchain; and the flags as run, with the checkout's path written `.`.
#
# Each set of inputs gives one agent because it is built once and copied, not
# because two builds agree: an -O build passes withoutActuallyEscaping's escape
# check the length of each source file's path (issue #2059), so a build from a
# checkout whose path has another length differs. The prefix maps keep the
# checkout's path out of any path text the compilers embed; no byte of the
# agent depends on them today.
#
# KERNOVA_AGENT_FAULT=hang-before-hello builds an agent that never dials,
# for the update rollback gate, and only in a Debug build.
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/tool-cache.sh
. "$repo/Tools/lib/tool-cache.sh"
# shellcheck source=lib/linux-swift.sh
. "$repo/Tools/lib/linux-swift.sh"
# shellcheck source=lib/linux-agent.sh
. "$repo/Tools/lib/linux-agent.sh"

usage() {
    echo 'usage: Tools/install-linux-guest-agent.sh [--path]' >&2
    exit 2
}
[ $# -le 1 ] || usage

swift_version="$(pinned_swift_version)"

# The targets under KernovaKit/Sources that kernova-agent is built from. The
# manifest is hashed too, so an edit to it that changes them misses the cache,
# and that build fails until this list names them.
agent_targets=(
    CKernovaAgentVersion CKernovaShims KernovaAgentCore KernovaAgentInstall KernovaAgentRuntime KernovaConsole
    KernovaContainer KernovaContainerPipeline KernovaDBus KernovaDigest KernovaFileTree KernovaLinuxAgent
    KernovaLogging KernovaPlatformLinux KernovaPlatformPOSIX KernovaSynchronization KernovaTreeTransfer KernovaWire
)

scratch="$repo/KernovaKit/.build/swiftly"
flags=(
    --scratch-path "$scratch"
    --swift-sdk "$(static_sdk_id "$swift_version")" --triple aarch64-swift-linux-musl
    -c release --product kernova-agent
    -Xswiftc -file-prefix-map -Xswiftc "$repo=."
    -Xswiftc -Xfrontend -Xswiftc -disable-incremental-llvm-codegen
    -Xcc "-ffile-prefix-map=$repo=."
    -Xlinker --strip-all
)

case "${KERNOVA_AGENT_FAULT:-}" in
    '') ;;
    hang-before-hello)
        if [ -n "${CONFIGURATION:-}" ] && [ "$CONFIGURATION" != Debug ]; then
            echo "error: KERNOVA_AGENT_FAULT is set in a $CONFIGURATION build; only Debug builds carry it" >&2
            exit 1
        fi
        flags+=(-Xswiftc -DKERNOVA_AGENT_FAULT_HANG_BEFORE_HELLO)
        ;;
    *) echo "error: KERNOVA_AGENT_FAULT=$KERNOVA_AGENT_FAULT is not a fault this build knows" >&2; exit 1 ;;
esac

paths=("Tools/${BASH_SOURCE[0]##*/}" Tools/lib/tool-cache.sh Tools/lib/linux-swift.sh Tools/lib/static-linux-sdk.sh
    Tools/lib/package-pins.sh Tools/lib/linux-agent.sh .swift-version KernovaKit/Package.swift
    Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
for target in "${agent_targets[@]}"; do paths+=("KernovaKit/Sources/$target"); done
values=()
for flag in "${flags[@]}"; do values+=("flag ${flag//"$repo"/.}"); done
inputs=(kernova-agent "${values[@]}" -- "${paths[@]}")

build_agent() {
    local missing built listed
    missing="$(swift_toolchain_missing "$swift_version")"
    if [ -n "$missing" ]; then
        echo "error: $missing is not installed: run \`make swift-toolchain\`" >&2
        return 1
    fi
    built="$(linux_swift package --scratch-path "$scratch" describe --type json | linux_agent_sources | sort)"
    listed="$(printf 'Sources/%s\n' "${agent_targets[@]}" | sort)"
    if [ "$built" != "$listed" ]; then
        echo "error: kernova-agent is built from these targets, which agent_targets in ${BASH_SOURCE[0]} must name:" >&2
        printf '%s\n' "$built" >&2
        return 1
    fi
    linux_swift build "${flags[@]}" >&2
    cp "$(linux_swift build "${flags[@]}" --show-bin-path)/kernova-agent" "$1/"
}

verify_agent() {
    check_linux_agent "$1/kernova-agent" && linux_agent_label "$1/kernova-agent" >/dev/null
}

case "${1:-}" in
    '') dir=$(tool_install build_agent verify_agent "${inputs[@]}") ;;
    --path) dir=$(tool_dir "${inputs[@]}") ;;
    *) usage ;;
esac
printf '%s\n' "$dir/kernova-agent"
