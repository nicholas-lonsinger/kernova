#!/usr/bin/env bash
# The app never asks Launch Services to open an application, its own bundle
# least of all. Launch Services matches an application by bundle identifier
# and brings forward whichever running copy it picks — the oldest, in every
# trial of #1377's probe — so an app opening its own bundle can activate a
# different copy of Kernova, which also receives a reopen and puts its library
# up. Bringing this copy forward is `NSApp.activate()` for an in-app click, and
# the requester's job for a request from outside the process.
#
# Flagged, on one line of code:
#   - any `openApplication(` call;
#   - `withApplicationAt:` naming `Bundle.main.bundleURL`, the
#     `open(_:withApplicationAt:configuration:)` route to the same request;
#   - `.open(Bundle.main.bundleURL`, opening the bundle as a document.
# A URL bound to a local first and passed on a later line is not traced.
#
# Scope is every tracked Swift file under Kernova/, the app target. The CLI and
# the relaunch helper launch the app from outside it and are not scanned.
#
# Line comments are stripped before matching, so prose may name what it
# forbids.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

findings=$(git ls-files 'Kernova/*.swift' \
    | tr '\n' '\0' \
    | xargs -0 awk '
        {
            code = $0
            sub(/\/\/.*$/, "", code)
            if (code ~ /openApplication[[:space:]]*\(/ \
                || code ~ /withApplicationAt:[[:space:]]*Bundle\.main\.bundleURL/ \
                || code ~ /\.open[[:space:]]*\([[:space:]]*Bundle\.main\.bundleURL/) {
                line = code
                sub(/^[[:space:]]+/, "", line)
                printf "%s:%d — %s\n", FILENAME, FNR, line
            }
        }
    ')
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-self-activation: $line" >&2
    done
    echo "check-self-activation: the app asks Launch Services to open an application, which activates whichever running copy it picks" >&2
    exit 1
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-self-activation: the scan exited $scan_status — at least one tracked Swift file went unread" >&2
    exit 1
fi

pass "self-activation: Kernova/ calls no openApplication and opens Bundle.main.bundleURL neither as a document nor withApplicationAt:"
