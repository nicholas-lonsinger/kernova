#!/bin/sh
#
# run-with-sample.sh — run a command under a wall-clock bound. When the bound
# expires, sample every xcodebuild test host still running into <out-dir>,
# print the head of each sample, and kill the command — so a stalled test run
# fails with the blocked thread's stack instead of the job cap cancelling it
# silently with the result bundle half-written.
#
# Usage: run-with-sample.sh <seconds> <out-dir> <command> [args...]
#
# Exits with the command's own status when it finishes in time, 124 after a
# sample. Requires /usr/bin/sample (macOS).

set -eu

LIMIT="${1:-}"
OUT="${2:-}"
if [ -z "$LIMIT" ] || [ -z "$OUT" ] || [ "$#" -lt 3 ]; then
    echo "error: usage: $0 <seconds> <out-dir> <command> [args...]" >&2
    exit 1
fi
shift 2

"$@" &
CMD=$!

elapsed=0
while kill -0 "$CMD" 2>/dev/null; do
    if [ "$elapsed" -ge "$LIMIT" ]; then
        echo "::error::No completion within ${LIMIT}s — sampling the test hosts, then killing the run."
        mkdir -p "$OUT"
        # `comm=` is the executable path. The app-hosted bundle runs inside
        # Kernova.app; the others run under xctest.
        ps -axo pid=,comm= | while read -r pid comm; do
            case "$comm" in
                */Kernova.app/Contents/MacOS/Kernova | */xctest | */xcodebuild) ;;
                *) continue ;;
            esac
            file="$OUT/$(basename "$comm")-$pid.txt"
            if sample "$pid" 5 -mayDie -file "$file" >/dev/null 2>&1; then
                echo "=== $file"
                head -n 120 "$file"
            else
                echo "=== could not sample $comm ($pid)"
            fi
        done
        pkill -x xcodebuild || true
        kill "$CMD" 2>/dev/null || true
        wait "$CMD" 2>/dev/null || true
        exit 124
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

set +e
wait "$CMD"
exit $?
