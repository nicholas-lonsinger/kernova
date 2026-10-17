#!/usr/bin/env bash
# The app never asks Launch Services to open an application, its own bundle
# least of all. Launch Services matches an application by bundle identifier
# and brings forward whichever running copy it picks — the oldest, in every
# trial of #1377's probe — so an app opening its own bundle can activate a
# different copy of Kernova, which also receives a reopen and puts its library
# up. Bringing this copy forward is `AppPresence.activate()` for an in-app
# click, and the requester's job for a request from outside the process.
#
# And the app reads and changes its own activation policy, hidden state and
# activation only through `AppPresence`: the unit tests run inside this app as
# their host, and a call that skips the stand-in a test hands in gives the
# host a Dock icon or asks for the front on the desktop the tests share.
#
# Flagged, on one line of code:
#   - any `openApplication(` call;
#   - `withApplicationAt:` naming `Bundle.main.bundleURL`, the
#     `open(_:withApplicationAt:configuration:)` route to the same request;
#   - `.open(Bundle.main.bundleURL`, opening the bundle as a document;
#   - outside Kernova/App/AppPresence.swift, `NSApp` (optional-chained or not)
#     or `NSApplication.shared` reaching `activate`, `activationPolicy`,
#     `setActivationPolicy`, `isActive`, `hide`, `unhide`,
#     `unhideWithoutActivation`, `unhideAllApplications`, `isHidden` or
#     `deactivate`, and `NSRunningApplication.current` reaching `activate` or
#     `hide`.
# A URL bound to a local first and passed on a later line is not traced, nor is
# an `NSApplication` bound to a local.
#
# Scope is every tracked Swift file the app or a test host runs as its own
# code — Kernova/, KernovaCore/Sources/KernovaVirtualization/ (Virtualization
# re-exports Cocoa), KernovaCore/Sources/KernovaUI/ and KernovaTestHost/ — or
# the files named as arguments, relative to the caller's directory — how
# Tools/tests/check-self-activation.sh drives it. The CLI and the relaunch
# helper launch the app from outside it and are not scanned.
#
# Line comments are stripped before matching, so prose may name what it
# forbids.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

presence_owner='Kernova/App/AppPresence.swift'

if [ "$#" -gt 0 ]; then
    list_files() { printf '%s\n' "$@"; }
else
    cd "$(git rev-parse --show-toplevel)" || exit 1
    list_files() {
        git ls-files 'Kernova/*.swift' 'KernovaCore/Sources/KernovaVirtualization/*.swift' \
            'KernovaCore/Sources/KernovaUI/*.swift' 'KernovaTestHost/*.swift'
    }
fi

findings=$(list_files "$@" \
    | tr '\n' '\0' \
    | xargs -0 awk -v owner="$presence_owner" '
        {
            code = $0
            sub(/\/\/.*$/, "", code)
            line = code
            sub(/^[[:space:]]+/, "", line)
            if (code ~ /openApplication[[:space:]]*\(/ \
                || code ~ /withApplicationAt:[[:space:]]*Bundle\.main\.bundleURL/ \
                || code ~ /\.open[[:space:]]*\([[:space:]]*Bundle\.main\.bundleURL/) {
                printf "%s:%d — %s\n", FILENAME, FNR, line
            } else if (FILENAME != owner && substr(FILENAME, length(FILENAME) - length(owner)) != "/" owner \
                && (code ~ /(NSApp[[:space:]]*\??|NSApplication\.shared)[[:space:]]*\.[[:space:]]*(activate|activationPolicy|setActivationPolicy|isActive|hide|unhide|unhideWithoutActivation|unhideAllApplications|isHidden|deactivate)([^A-Za-z0-9_]|$)/ \
                    || code ~ /NSRunningApplication\.current[[:space:]]*\.[[:space:]]*(activate|hide)([^A-Za-z0-9_]|$)/)) {
                printf "%s:%d — %s\n", FILENAME, FNR, line
            }
        }
    ')
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-self-activation: $line" >&2
    done
    echo "check-self-activation: the app asks Launch Services to open an application, which activates whichever running copy it picks, or reaches its own activation, policy or hidden state around AppPresence" >&2
    exit 1
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-self-activation: the scan exited $scan_status — at least one tracked Swift file went unread" >&2
    exit 1
fi

pass "self-activation: the app, KernovaUI and the test host call no openApplication, opens Bundle.main.bundleURL neither as a document nor withApplicationAt:, and reaches its own activation only through AppPresence"
