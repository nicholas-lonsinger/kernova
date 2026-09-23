#!/usr/bin/env bash
# Launches a Kernova build and confirms the process that comes up is that
# build. Launch Services hands an open to a running instance of the same bundle
# identifier as a reopen, whichever copy's path was opened (`man open`, -n), so
# with another Kernova up the open succeeds and leaves the old binary
# answering. Every running Kernova is quit first through its own bundled
# `kernova quit`, which save-suspends its VMs and returns once Launch Services
# has released it; the launched process's executable is then compared with the
# build's.
#
# Usage:
#   .agents/skills/launch-build/launch-build.sh [--timeout <seconds>] <binary>
#
#   <binary>    The build's executable, as a green build verdict's `binary=`
#               line names it; the `binary=` prefix may stay on.
#   --timeout   How long each wait lasts (default 60): for one running copy to
#               be gone once asked to quit, and for the build to come up once
#               opened. A wait that runs out signals nothing, so a re-run picks
#               it back up.
#
# A running copy is one Launch Services holds under the build's own bundle
# identifier — the registry the open is routed by — so a copy at the build's
# own path is quit too: it is running whatever image that path held when it
# launched. A copy whose tool is missing, exits non-zero, or leaves it running
# (its socket reached another copy, or nothing) is sent the quit Apple event
# instead, addressed to that process alone; the app treats a scripted quit as
# the same save-suspending quit. Nothing is ever signalled: a signal skips the
# save pass.
#
# Output is one line, the verdict, on stdout; what the tools themselves report
# goes to stderr. A path, when there is one, is the line's last field:
#   launch-build: verdict=<token> [key=value ...]
#
# Verdict tokens and exit codes:
#   0  running       the build is up: pid= is its process, binary= the
#                    executable
#   1  mismatch      every copy was gone before the open, yet the copy up now
#                    is not the build: pid= and running= name it
#   2  not-running   no copy is up: reason=open-failed (open's error is on
#                    stderr), or reason=not-registered when none registered
#                    within the wait
#   3  quit-timeout  pid= was asked to quit and is still up when its wait ran
#                    out; running= names its executable
#   4  quit-refused  the quit Apple event could not be sent to pid=; running=
#                    names its executable, and osascript's error is on stderr
#   5  setup-error   reason= says which: usage (argument= names it), no-build
#                    (no executable at path=), not-an-app (path= is not inside
#                    a .app's Contents/MacOS), no-bundle-identifier (path=
#                    names the bundle), or query-failed (Launch Services
#                    could not be asked)

set -uo pipefail

TIMEOUT=60
POLL=0.2
binary=

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

verdict() { # <exit-code> <token> [key=value ...]
    _code="$1"; _token="$2"; shift 2
    printf 'launch-build: verdict=%s%s\n' "$_token" "${*:+ $*}"
    exit "$_code"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            [ $# -ge 2 ] || { usage; verdict 5 setup-error reason=usage "argument=$1"; }
            TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; verdict 5 setup-error reason=usage "argument=$1" ;;
        *)
            [ -z "$binary" ] || { usage; verdict 5 setup-error reason=usage "argument=$1"; }
            binary="${1#binary=}"; shift ;;
    esac
done

case "$TIMEOUT" in
    '' | *[!0-9]*) usage; verdict 5 setup-error reason=usage "argument=--timeout $TIMEOUT" ;;
esac
TIMEOUT=$((10#$TIMEOUT))
[ "$TIMEOUT" -gt 0 ] || { usage; verdict 5 setup-error reason=usage "argument=--timeout $TIMEOUT"; }
[ -n "$binary" ] || { usage; verdict 5 setup-error reason=usage argument=-; }

# The path with every symlink in its directories resolved, so two spellings of
# one file compare equal; a path whose directory is gone is returned as given.
canonical() {
    local dir
    dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || { printf '%s\n' "$1"; return; }
    printf '%s/%s\n' "$dir" "$(basename "$1")"
}

if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
    verdict 5 setup-error reason=no-build "path=$binary"
fi
binary="$(canonical "$binary")"
bundle="${binary%/Contents/MacOS/*}"
if [ "$bundle" = "$binary" ] || [ "${bundle%.app}" = "$bundle" ]; then
    verdict 5 setup-error reason=not-an-app "path=$binary"
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null)"
[ -n "$bundle_id" ] || verdict 5 setup-error reason=no-bundle-identifier "path=$bundle"

# Launch Services' own view, through NSRunningApplication. `list <bundle-id>`
# prints "<pid>\t<executable>" per registered copy. `quit <pid> <bundle-id>`
# sends that one process the quit Apple event and prints sent or refused — or
# gone when the pid no longer names a copy of that bundle, so a reused pid is
# never sent anything.
LS_QUERY='
ObjC.import("AppKit");
function run(argv) {
    if (argv[0] === "list") {
        return $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[1]).js
            .map(function (app) {
                var url = app.executableURL;
                return app.processIdentifier + "\t" + (url.isNil() ? "" : url.path.js);
            })
            .join("\n");
    }
    if (argv[0] === "quit") {
        var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[1]));
        if (app.isNil() || app.bundleIdentifier.js !== argv[2]) return "gone";
        return app.terminate ? "sent" : "refused";
    }
    throw new Error("unknown query " + argv[0]);
}'
ls_query() { osascript -l JavaScript -e "$LS_QUERY" "$@"; }

# Sets $running to every registered copy, "<pid>\t<canonical executable>" per
# line, lowest pid first, so the copy acted on stays the same across polls.
running=
refresh() {
    local out pid exe
    out="$(ls_query list "$bundle_id")" || verdict 5 setup-error reason=query-failed
    running="$(
        while IFS=$'\t' read -r pid exe; do
            [ -n "$pid" ] && printf '%s\t%s\n' "$pid" "$(canonical "$exe")"
        done <<<"$out" | sort -n
    )"
}

contains() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# Runs a copy's own `kernova quit`, which blocks through the save pass. Returns
# 1 when the deadline passes first; the tool is then stopped, which leaves the
# quit it delivered running in the app.
run_tool() { # <tool> <deadline>
    local tool_pid
    "$1" quit >/dev/null &
    tool_pid=$!
    while kill -0 "$tool_pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$2" ]; then
            kill "$tool_pid" 2>/dev/null
            wait "$tool_pid" 2>/dev/null
            return 1
        fi
        sleep "$POLL"
    done
    # Its exit status decides nothing: the next refresh says what is still up.
    wait "$tool_pid" 2>/dev/null
    return 0
}

# ---- quit every running copy ------------------------------------------------

asked=        # pids whose own tool has run
sent=         # pids sent the quit Apple event
current=      # the pid the deadline belongs to
deadline=0
while :; do
    refresh
    [ -n "$running" ] || break
    first="${running%%$'\n'*}"
    pid="${first%%$'\t'*}"
    exe="${first#*$'\t'}"
    if [ "$pid" != "$current" ]; then
        current="$pid"
        deadline=$((SECONDS + TIMEOUT))
    fi
    [ "$SECONDS" -lt "$deadline" ] || verdict 3 quit-timeout "pid=$pid" "running=$exe"

    tool="${exe%/Contents/MacOS/*}/Contents/Helpers/kernova"
    if ! contains "$asked" "$pid" && [ -x "$tool" ]; then
        asked="$asked $pid"
        run_tool "$tool" "$deadline" || verdict 3 quit-timeout "pid=$pid" "running=$exe"
        continue
    fi
    if ! contains "$sent" "$pid"; then
        sent="$sent $pid"
        if ! answer="$(ls_query quit "$pid" "$bundle_id")" || [ "$answer" = refused ]; then
            verdict 4 quit-refused "pid=$pid" "running=$exe"
        fi
    fi
    sleep "$POLL"
done

# ---- launch the build and confirm it is what came up ------------------------

open "$bundle" >/dev/null || verdict 2 not-running reason=open-failed

deadline=$((SECONDS + TIMEOUT))
while :; do
    refresh
    if [ -n "$running" ]; then
        build_pid=
        while IFS=$'\t' read -r pid exe; do
            [ "$exe" = "$binary" ] || verdict 1 mismatch "pid=$pid" "running=$exe"
            [ -n "$build_pid" ] || build_pid="$pid"
        done <<<"$running"
        verdict 0 running "pid=$build_pid" "binary=$binary"
    fi
    [ "$SECONDS" -lt "$deadline" ] || verdict 2 not-running reason=not-registered
    sleep "$POLL"
done
