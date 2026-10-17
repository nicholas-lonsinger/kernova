#!/usr/bin/env bash
# Fixture tests for Tools/check-self-activation.sh: which spellings it flags,
# and that AppPresence.swift alone may reach the app's own activation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-self-activation.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect <name> <want> <swift source> [<path under $tmp>] — the check, run over
# a file holding the source, reports exactly the lines in <want>
# (space-separated, empty for a pass).
expect() {
    local name=$1 want=$2 file="$tmp/${4:-$1.swift}" output status got
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$3" >"$file"
    output=$(bash "$check_script" "$file" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-self-activation: $file:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

expect presence-calls '1 2 3 4 5 6 7 8' 'NSApp.activate()
NSApp?.activate()
NSApp.setActivationPolicy(.regular)
let policy = NSApp.activationPolicy()
NSApplication.shared.unhideWithoutActivation()
NSApp.unhideAllApplications(nil)
if NSApp.isHidden || NSApp.isActive {}
NSRunningApplication.current.activate()'

expect other-members '' 'NSApp.mainMenu?.cancelTracking()
let event = NSApp.currentEvent
let shown = NSApp.isActiveWindowShown
NSLayoutConstraint.activate([])'

expect prose-in-a-comment '' '// NSApp.activate() is AppPresence'"'"'s job'

expect presence-owner '' 'NSApp.activate()
NSApp.setActivationPolicy(policy)' 'KernovaCore/Sources/KernovaUI/App/AppPresence.swift'

expect launch-services '1 2 3' 'NSWorkspace.shared.openApplication(at: url, configuration: c)
NSWorkspace.shared.open([u], withApplicationAt: Bundle.main.bundleURL, configuration: c)
NSWorkspace.shared.open(Bundle.main.bundleURL)'

if [ "$FAIL" -gt 0 ]; then
    printf 'check-self-activation fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-self-activation fixtures: all passed\n'
