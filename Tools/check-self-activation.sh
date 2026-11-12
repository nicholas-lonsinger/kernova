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
# Flagged, on one line of code or a member at the start of the line after its
# receiver:
#   - any `openApplication(` call;
#   - `withApplicationAt:` naming `Bundle.main.bundleURL`, the
#     `open(_:withApplicationAt:configuration:)` route to the same request;
#   - `.open(Bundle.main.bundleURL`, opening the bundle as a document;
#   - outside Kernova/App/AppKitSessionFocus.swift:
#     - `NSApp`, `NSApplication.shared` or `KernovaApplication.shared` —
#       optional-chained, force-unwrapped or neither, and bare or in
#       parentheses with or without an `as` cast — reaching `activate`,
#       `activationPolicy`, `setActivationPolicy`, `isActive`, `hide`,
#       `unhide`, `unhideWithoutActivation`, `isHidden`, `deactivate`,
#       `keyWindow` or `mainWindow`; `NSRunningApplication.current` reaching
#       `hide`, `unhide`, `isActive` or `isHidden`; and an `.activate(` on a
#       line naming `NSRunningApplication` or `runningApplications`;
#     - a read of `frontmostApplication`;
#     - a call to `makeKeyAndOrderFront(`, `makeKey(`, `makeMain(`,
#       `orderFrontRegardless(`, `toggleFullScreen(`, `miniaturize(`,
#       `deminiaturize(`, `orderWindow(`, `setIsVisible(`,
#       `hideOtherApplications(`, `unhideAllApplications(`, `arrangeInFront(`,
#       `miniaturizeAll(`, `orderFrontStandardAboutPanel(` or `showWindow(`,
#       each of which changes what is on screen or which window is key;
#     - a `#selector`, or a `Selector(…)` or `NSSelectorFromString(…)` of a
#       string literal, naming any app member or call above, or outside
#       KernovaUITests/ `orderFront` or `orderBack`, unless written as an
#       `action:` argument or assigned to `.action`: that selector AppKit sends
#       on the user's click or key equivalent, as the menu bar's Hide Others
#       and Bring All to Front do;
#     - outside KernovaCore/Sources/KernovaUI/Views/Sidebar/SidebarViewController.swift,
#       whose row emphasis draws from its window's key state, a read of
#       `isKeyWindow`, and everywhere a read of `isMainWindow`;
#     - outside KernovaUITests/, which orders its parked test windows in
#       itself, a call to `orderFront(` or `orderBack(`, and a read of
#       `.isOnActiveSpace`.
# A URL bound to a local first and passed on a later line is not traced, nor is
# an `NSApplication` or `NSRunningApplication` bound to a local.
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
key_emphasis='KernovaCore/Sources/KernovaUI/Views/Sidebar/SidebarViewController.swift'

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
    | xargs -0 awk -v owner="$focus_owner" -v emphasis="$key_emphasis" '
        function report() { printf "%s:%d — %s\n", FILENAME, FNR, line }
        function ends(path) { return FILENAME == path || substr(FILENAME, length(FILENAME) - length(path)) == "/" path }
        BEGIN {
            app_core = "(NSApp|(NS|Kernova)Application[[:space:]]*\\.[[:space:]]*shared)"
            app = "(^|[^A-Za-z0-9_])(" app_core "|\\([[:space:]]*" app_core "([[:space:]]+as[?!]?[[:space:]]+[A-Za-z0-9_.]+)?[[:space:]]*\\))[[:space:]]*[?!]?"
            app_names = "activate|activationPolicy|setActivationPolicy|isActive|hide|unhide|unhideWithoutActivation|isHidden|deactivate|keyWindow|mainWindow"
            app_members = "(" app_names ")"
            current = "NSRunningApplication[[:space:]]*\\.[[:space:]]*current"
            current_members = "(hide|unhide|isActive|isHidden)"
            keying_names = "makeKeyAndOrderFront|makeKey|makeMain|orderFrontRegardless|toggleFullScreen|miniaturize|deminiaturize|orderWindow|setIsVisible|hideOtherApplications|unhideAllApplications|arrangeInFront|miniaturizeAll|orderFrontStandardAboutPanel|showWindow"
            keying = "(" keying_names ")"
            selected = keying_names "|" app_names
            end_word = "([^A-Za-z0-9_]|$)"
            string_selector = "(^|[^A-Za-z0-9_])(Selector[[:space:]]*\\([[:space:]]*\\(?|NSSelectorFromString[[:space:]]*\\()[[:space:]]*\""
            member_start = "^[[:space:]]*\\.[[:space:]]*"
        }
        FNR == 1 { chain = "" }
        {
            code = $0
            sub(/\/\/.*$/, "", code)
            line = code
            sub(/^[[:space:]]+/, "", line)
            is_owner = ends(owner)
            in_tests = FILENAME ~ /(^|\/)KernovaUITests\//
            # A selector AppKit sends on a user action is not Kernova reaching the focus.
            scan = code
            gsub(/(action[[:space:]]*:|\.action[[:space:]]*=)[[:space:]]*(#selector|Selector|NSSelectorFromString)[[:space:]]*\([^()]*(\([^()]*\)[^()]*)*\)/, "", scan)
            sent = selected (in_tests ? "" : "|orderFront|orderBack")
            continued = scan ~ member_start
            receiver = continued ? chain : ""
            chain = continued ? chain scan : scan
            if (code ~ /openApplication[[:space:]]*\(/ \
                || code ~ /withApplicationAt:[[:space:]]*Bundle\.main\.bundleURL/ \
                || code ~ /\.open[[:space:]]*\([[:space:]]*Bundle\.main\.bundleURL/) {
                report()
            } else if (is_owner) {
                next
            } else if (scan ~ (app "[[:space:]]*\\.[[:space:]]*" app_members end_word) \
                || scan ~ (current "[[:space:]]*\\.[[:space:]]*" current_members end_word) \
                || (receiver ~ (app "[[:space:]]*$") && scan ~ (member_start app_members end_word)) \
                || (receiver ~ (current "[[:space:]]*$") && scan ~ (member_start current_members end_word)) \
                || ((scan ~ /(NSRunningApplication|runningApplications)/ || (continued && receiver ~ /(NSRunningApplication|runningApplications)/)) \
                    && scan ~ /\.[[:space:]]*activate[[:space:]]*\(/) \
                || scan ~ ("(^|[^A-Za-z0-9_])frontmostApplication" end_word) \
                || scan ~ ("(^|[^A-Za-z0-9_])" keying "[[:space:]]*\\(") \
                || scan ~ ("#selector[[:space:]]*\\(([A-Za-z0-9_]+[[:space:]]*\\.[[:space:]]*)*(" sent ")" end_word) \
                || scan ~ (string_selector "(" sent ")(:|\"|[A-Z][A-Za-z0-9_]*:)") \
                || scan ~ ("(^|[^A-Za-z0-9_])isMainWindow" end_word) \
                || (!ends(emphasis) && scan ~ ("(^|[^A-Za-z0-9_])isKeyWindow" end_word))) {
                report()
            } else if (!in_tests \
                && (scan ~ /(^|[^A-Za-z0-9_])(orderFront|orderBack)[[:space:]]*\(/ \
                    || scan ~ /\.[[:space:]]*isOnActiveSpace([^A-Za-z0-9_]|$)/)) {
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
