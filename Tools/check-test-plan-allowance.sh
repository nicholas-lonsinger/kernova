#!/usr/bin/env bash
# The test plan's per-test execution-time allowance is what lets one stuck case
# fail alone instead of stalling the bundle. Set at or below `testWaitBackstop`
# it would instead kill tests whose own wait was about to fail them by name,
# trading a named stuck condition for a bare timeout — and an allowance the
# plan does not enforce (`testTimeoutsEnabled` off) bounds nothing at all.
#
# Nothing links the plan to the constant, so this check is what holds them
# together.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

plan="Kernova.xcodeproj/xcshareddata/xctestplans/Kernova.xctestplan"
waits="KernovaKit/Sources/KernovaTestSupport/AsyncWaits.swift"

status=0

for f in "$plan" "$waits"; do
    if [ ! -f "$f" ]; then
        echo "check-test-plan-allowance: $f is missing" >&2
        status=1
    fi
done
[ "$status" -eq 0 ] || exit "$status"

# `"key" : value`, the spelling Xcode writes, tolerant of the spacing.
plan_value() {
    sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\([0-9a-z.]*\).*/\1/p" "$plan" | head -1
}

backstop=$(sed -n 's/^[[:space:]]*public let testWaitBackstop: TimeInterval[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' "$waits" | head -1)
timeouts_enabled=$(plan_value testTimeoutsEnabled)

if [ -z "$backstop" ]; then
    echo "check-test-plan-allowance: no testWaitBackstop value in $waits" >&2
    exit 1
fi

if [ "$timeouts_enabled" != "true" ]; then
    echo "check-test-plan-allowance: $plan sets testTimeoutsEnabled = ${timeouts_enabled:-<nothing>}, expected true — an allowance it does not enforce bounds nothing" >&2
    status=1
fi

# The backstop is a `TimeInterval`, so both comparisons are floating point.
exceeds_backstop() {
    local key="$1"
    local value
    value=$(plan_value "$key")
    case "$value" in
        '' | *[!0-9.]*)
            echo "check-test-plan-allowance: $plan has no numeric $key (read: ${value:-<nothing>})" >&2
            return 1
            ;;
    esac
    if ! awk -v allowance="$value" -v backstop="$backstop" 'BEGIN { exit !(allowance > backstop) }'; then
        echo "check-test-plan-allowance: $plan sets $key = $value, which does not exceed testWaitBackstop ($backstop) — a stuck case would fail by bare timeout instead of by its own wait" >&2
        return 1
    fi
}

exceeds_backstop defaultTestExecutionTimeAllowance || status=1
exceeds_backstop maximumTestExecutionTimeAllowance || status=1

if [ "$status" -eq 0 ]; then
    echo "  ✓ test plan: per-test allowance exceeds testWaitBackstop (${backstop} s)"
fi
exit "$status"
