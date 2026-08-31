#!/usr/bin/env bash
# The guest agent targets take their deployment floor from
# KERNOVA_AGENT_DEPLOYMENT_TARGET in Config/Base.xcconfig; KernovaKit compiles
# into the agent and must not raise it. SwiftPM cannot read an xcconfig, so
# Package.swift's `.macOS(.vN)` is the one restatement of that floor — this
# check is what holds the two together.
#
# It also holds the agent xcconfigs to the variable, so raising the floor in
# the file named for the agent — the obvious place to look — cannot bypass the
# comparison above.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

base="Config/Base.xcconfig"
manifest="KernovaKit/Package.swift"
agent_xcconfigs=(
    "Config/Targets/KernovaMacOSAgent.xcconfig"
    "Config/Targets/KernovaMacOSAgentTests.xcconfig"
)

status=0

for f in "$base" "$manifest" "${agent_xcconfigs[@]}"; do
    if [ ! -f "$f" ]; then
        echo "check-agent-deployment-floor: $f is missing" >&2
        status=1
    fi
done
[ "$status" -eq 0 ] || exit "$status"

xcconfig_floor=$(sed -n 's/^[[:space:]]*KERNOVA_AGENT_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$base")
manifest_floor=$(sed -n 's/^[[:space:]]*\.macOS(\.v\([0-9_]*\)).*/\1/p' "$manifest" | tr '_' '.')

if [ -z "$xcconfig_floor" ]; then
    echo "check-agent-deployment-floor: no KERNOVA_AGENT_DEPLOYMENT_TARGET in $base" >&2
    status=1
fi

if [ -z "$manifest_floor" ]; then
    echo "check-agent-deployment-floor: no .macOS(.vN) platform in $manifest" >&2
    status=1
fi

# `.macOS(.v12)` means 12.0, so compare on the major version alone.
if [ "$status" -eq 0 ] && [ "${xcconfig_floor%%.*}" != "${manifest_floor%%.*}" ]; then
    echo "check-agent-deployment-floor: $base says $xcconfig_floor, $manifest says $manifest_floor" >&2
    status=1
fi

# A literal here would raise the agent's floor without moving the value the
# comparison above reads, so require the reference.
for f in "${agent_xcconfigs[@]}"; do
    assigned=$(sed -n 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*//p' "$f" | head -1 | sed 's/[[:space:]]*$//')
    if [ "$assigned" != '$(KERNOVA_AGENT_DEPLOYMENT_TARGET)' ]; then
        echo "check-agent-deployment-floor: $f sets MACOSX_DEPLOYMENT_TARGET = ${assigned:-<nothing>}, expected \$(KERNOVA_AGENT_DEPLOYMENT_TARGET)" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "  ✓ deployment floor: agent xcconfigs and KernovaKit manifest agree ($xcconfig_floor)"
fi
exit "$status"
