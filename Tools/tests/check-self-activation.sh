#!/usr/bin/env bash
# Fixture tests for Tools/check-self-activation.sh: which spellings it flags,
# that AppKitSessionFocus.swift alone may reach the session's focus, and that
# KernovaUITests/ may order its own windows.

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

expect focus-reads '1 2 3' 'let key = NSApp.keyWindow
let main = NSApp?.mainWindow
let shared = NSApplication.shared.keyWindow'

expect window-writes '1 2 3 4 5 6 7' 'window.makeKeyAndOrderFront(nil)
window.makeKey()
window.makeMain()
window.orderFrontRegardless()
window.toggleFullScreen(nil)
window.miniaturize(nil)
NSApp.orderFrontStandardAboutPanel(options: [:])'

expect window-writes-in-tests '1 2 3 4 5 6 7 8' 'window.makeKeyAndOrderFront(nil)
window.makeKey()
window.makeMain()
window.orderFrontRegardless()
window.toggleFullScreen(nil)
window.miniaturize(nil)
NSApp.orderFrontStandardAboutPanel(options: [:])
let key = NSApp.keyWindow' 'KernovaUITests/Writes.swift'

expect window-ordering '1 2 3 4' 'controller.showWindow(nil)
window.orderFront(nil)
window.orderBack(nil)
let here = window.isOnActiveSpace' 'KernovaCore/Sources/KernovaUI/App/Ordering.swift'

expect window-ordering-in-tests '' 'window.orderFront(nil)
window.orderBack(nil)
let here = window.isOnActiveSpace' 'KernovaUITests/Ordering.swift'

expect other-members '' 'NSApp.mainMenu?.cancelTracking()
let event = NSApp.currentEvent
let shown = NSApp.isActiveWindowShown
NSLayoutConstraint.activate([])
focus.present(window, .keyAndFront)
focus.toggleFullScreenMode(of: window)
window.orderOut(nil)
let drawsKey = window.isKeyWindow
let standing = WindowStanding(isVisible: true, isMiniaturized: false, isOnActiveSpace: true)'

expect prose-in-a-comment '' '// NSApp.activate() is SessionFocus'"'"'s job
/// `makeKeyAndOrderFront` is SessionFocus'"'"'s too'

expect focus-owner '' 'NSApp.activate()
NSApp.setActivationPolicy(policy)
let key = NSApp.keyWindow
window.makeKeyAndOrderFront(nil)
window.orderBack(nil)
let here = window.isOnActiveSpace' 'Kernova/App/AppKitSessionFocus.swift'

expect protocol-file-in-the-tests-reach '1' 'NSApp.activate()' 'KernovaCore/Sources/KernovaUI/App/SessionFocus.swift'

expect launch-services '1 2 3' 'NSWorkspace.shared.openApplication(at: url, configuration: c)
NSWorkspace.shared.open([u], withApplicationAt: Bundle.main.bundleURL, configuration: c)
NSWorkspace.shared.open(Bundle.main.bundleURL)'

if [ "$FAIL" -gt 0 ]; then
    printf 'check-self-activation fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-self-activation fixtures: all passed\n'
