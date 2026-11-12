#!/usr/bin/env bash
# The app never asks Launch Services to open an application, its own bundle
# least of all. Launch Services matches an application by bundle identifier
# and brings forward whichever running copy it picks — the oldest, in every
# trial of #1377's probe — so an app opening its own bundle can activate a
# different copy of Kernova, which also receives a reopen and puts its library
# up. Bringing this copy forward is `SessionFocus.activate()` for an in-app
# click, and the requester's job for a request from outside the process.
#
# And the app reaches its activation, activation policy and hidden state, the
# key and main window, and the calls below that order a window in or make it
# key only through `SessionFocus`, whose AppKit implementation lives in the app
# target alone: the unit tests run KernovaUI and KernovaUITests inside
# KernovaTestHost, and a call that skips the stand-in a test hands in gives the
# host a Dock icon, asks for the front, or puts a window on the desktop the
# tests share. Sheets, alerts, popovers and open and save panels go on screen
# through AppKit's own calls, which this check does not flag.
#
# Flagged, on one line of code:
#   - any `openApplication(` call;
#   - `withApplicationAt:` naming `Bundle.main.bundleURL`, the
#     `open(_:withApplicationAt:configuration:)` route to the same request;
#   - `.open(Bundle.main.bundleURL`, opening the bundle as a document;
#   - outside Kernova/App/AppKitSessionFocus.swift:
#     - `NSApp` (optional-chained or not) or `NSApplication.shared` reaching
#       `activate`, `activationPolicy`, `setActivationPolicy`, `isActive`,
#       `hide`, `unhide`, `unhideWithoutActivation`, `unhideAllApplications`,
#       `isHidden`, `deactivate`, `keyWindow` or `mainWindow`, and
#       `NSRunningApplication.current` reaching `activate` or `hide`;
#     - a call to `makeKeyAndOrderFront(`, `makeKey(`, `makeMain(`,
#       `orderFrontRegardless(`, `toggleFullScreen(`, `miniaturize(`,
#       `orderFrontStandardAboutPanel(` or `showWindow(`, which makes the
#       window key;
#     - outside KernovaUITests/, which orders its parked test windows in
#       itself, a call to `orderFront(` or `orderBack(`, and a read of
#       `.isOnActiveSpace`.
# A URL bound to a local first and passed on a later line is not traced, nor is
# an `NSApplication` bound to a local.
#
# Scope is every tracked Swift file the app or a test host runs as its own
# code — Kernova/, KernovaCore/Sources/KernovaVirtualization/ (Virtualization
# re-exports Cocoa), KernovaCore/Sources/KernovaUI/, KernovaTestHost/ and
# KernovaUITests/ — or the files named as arguments, relative to the caller's
# directory — how Tools/tests/check-self-activation.sh drives it. The CLI and
# the relaunch helper launch the app from outside it and are not scanned.
#
# Line comments are stripped before matching, so prose may name what it
# forbids.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

focus_owner='Kernova/App/AppKitSessionFocus.swift'

if [ "$#" -gt 0 ]; then
    list_files() { printf '%s\n' "$@"; }
else
    cd "$(git rev-parse --show-toplevel)" || exit 1
    list_files() {
        git ls-files 'Kernova/*.swift' 'KernovaCore/Sources/KernovaVirtualization/*.swift' \
            'KernovaCore/Sources/KernovaUI/*.swift' 'KernovaTestHost/*.swift' 'KernovaUITests/*.swift'
    }
fi

findings=$(list_files "$@" \
    | tr '\n' '\0' \
    | xargs -0 awk -v owner="$focus_owner" '
        function report() { printf "%s:%d — %s\n", FILENAME, FNR, line }
        {
            code = $0
            sub(/\/\/.*$/, "", code)
            line = code
            sub(/^[[:space:]]+/, "", line)
            is_owner = FILENAME == owner || substr(FILENAME, length(FILENAME) - length(owner)) == "/" owner
            in_tests = FILENAME ~ /(^|\/)KernovaUITests\//
            if (code ~ /openApplication[[:space:]]*\(/ \
                || code ~ /withApplicationAt:[[:space:]]*Bundle\.main\.bundleURL/ \
                || code ~ /\.open[[:space:]]*\([[:space:]]*Bundle\.main\.bundleURL/) {
                report()
            } else if (is_owner) {
                next
            } else if (code ~ /(NSApp[[:space:]]*\??|NSApplication\.shared)[[:space:]]*\.[[:space:]]*(activate|activationPolicy|setActivationPolicy|isActive|hide|unhide|unhideWithoutActivation|unhideAllApplications|isHidden|deactivate|keyWindow|mainWindow)([^A-Za-z0-9_]|$)/ \
                || code ~ /NSRunningApplication\.current[[:space:]]*\.[[:space:]]*(activate|hide)([^A-Za-z0-9_]|$)/ \
                || code ~ /(^|[^A-Za-z0-9_])(makeKeyAndOrderFront|makeKey|makeMain|orderFrontRegardless|toggleFullScreen|miniaturize|orderFrontStandardAboutPanel|showWindow)[[:space:]]*\(/) {
                report()
            } else if (!in_tests \
                && (code ~ /(^|[^A-Za-z0-9_])(orderFront|orderBack)[[:space:]]*\(/ \
                    || code ~ /\.[[:space:]]*isOnActiveSpace([^A-Za-z0-9_]|$)/)) {
                report()
            }
        }
    ')
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-self-activation: $line" >&2
    done
    echo "check-self-activation: the app asks Launch Services to open an application, which activates whichever running copy it picks, or reaches the login session's focus — its activation, policy, hidden state, key or main window, or how a window goes on screen — around SessionFocus" >&2
    exit 1
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-self-activation: the scan exited $scan_status — at least one tracked Swift file went unread" >&2
    exit 1
fi

pass "self-activation: the app, KernovaUI, the test host and its tests call no openApplication, open Bundle.main.bundleURL neither as a document nor withApplicationAt:, and reach the session's focus only through SessionFocus"
