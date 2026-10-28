#!/usr/bin/env bash
# KERNOVA_LINUX_AGENT_FAULT builds a deliberately broken Linux guest agent for
# the update-rollback gate, so a Release build never carries one. Every
# assignment of it in Config/'s xcconfigs — the tracked ones and the
# gitignored Local.xcconfig, where a developer sets it — and in the project
# file is conditioned `[config=Debug]` or assigns nothing.
# Tools/build-linux-guest-agent.sh refuses one in a Release build too, which
# covers a command-line override no file shows.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(git ls-files 'Config/*.xcconfig' Kernova.xcodeproj/project.pbxproj)
[ -f Config/Local.xcconfig ] && files+=(Config/Local.xcconfig)

violations=$(awk '
    {
        line = $0
        sub(/\/\/.*/, "", line)
        if (line !~ /KERNOVA_LINUX_AGENT_FAULT/) next
        if (line ~ /KERNOVA_LINUX_AGENT_FAULT\[config=Debug\][[:space:]]*=/) next
        if (line ~ /KERNOVA_LINUX_AGENT_FAULT[[:space:]]*=[[:space:]]*;?[[:space:]]*$/) next
        printf "  %s:%d: %s\n", FILENAME, FNR, $0
    }
' "${files[@]}")

if [ -n "$violations" ]; then
    echo "check-linux-agent-fault: KERNOVA_LINUX_AGENT_FAULT is set outside [config=Debug]:" >&2
    printf '%s\n' "$violations" >&2
    exit 1
fi

pass "Linux agent fault: set only for Debug"
