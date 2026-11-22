#!/usr/bin/env bash
# Writes `kernova-agent`, the static aarch64 Linux guest agent, where it is
# wanted, mode 0644: a copy of the one Tools/install-linux-guest-agent.sh
# builds once per set of inputs, with its label written in, checked to be an
# agent Kernova can bundle. An output already holding those bytes is left
# untouched.
#
# Usage:
#   Tools/build-linux-guest-agent.sh
#     as the KernovaLinuxGuestAgent target's "Build Linux Guest Agent" phase:
#     labels the agent "<MARKETING_VERSION> (<build number>)" and writes the
#     phase's one declared output
#   Tools/build-linux-guest-agent.sh --output <file> [--label <label>]
#     anywhere else; the label defaults to "development"

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

agent="$("$repo/Tools/install-linux-guest-agent.sh")"

mkdir -p "$(dirname "$output")"
staged="$(mktemp "$(dirname "$output")/.kernova-agent.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$agent" "$staged"
stamp_linux_agent_label "$staged" "$label"
check_linux_agent "$staged"
cmp -s "$staged" "$output" || mv "$staged" "$output"
chmod 0644 "$output"
