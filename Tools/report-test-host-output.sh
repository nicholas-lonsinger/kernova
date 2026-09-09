#!/bin/sh
# report-test-host-output.sh — print what each test host process wrote to its
# own stdout/stderr during a test run.
#
# Usage: report-test-host-output.sh [<result-bundle>]
#        (default: artifacts/TestResults.xcresult)
#
# xcodebuild's stream carries test results; a host that crashes, traps, or
# freezes explains itself only here — an AppKit/HIToolbox `[HIExceptions]
# FAULT` line, a Swift runtime trap, a crash-report header. `Staging/` holds
# those files while the run is in flight, so a killed or timed-out run still
# has them even though nothing was sealed into the bundle's object store;
# `xcresulttool export diagnostics` reaches the same files once the bundle is
# finished. Prints a line and exits 0 on every failure — this reports on a
# failed step and must not replace its error with its own.

set -u

BUNDLE="${1:-artifacts/TestResults.xcresult}"
TAIL_LINES=60
PATTERN='FAULT|Exception|Crash|Fatal error'
CAPTURE_NAME='StandardOutputAndStandardError.txt'

if [ ! -d "$BUNDLE" ]; then
    echo "No test result bundle at $BUNDLE — skipping test-host output report."
    exit 0
fi

files="$(mktemp)" || exit 0
exported=
trap 'rm -f "$files"; [ -z "$exported" ] || rm -rf "$exported"' EXIT

find "$BUNDLE/Staging" -name "$CAPTURE_NAME" >"$files" 2>/dev/null

if [ ! -s "$files" ]; then
    exported="$(mktemp -d)" || exit 0
    # Keep stderr: a rejected flag or an unreadable bundle otherwise degrades
    # this to a silent no-op with nothing to debug from.
    if ! error="$(xcrun xcresulttool export diagnostics \
        --path "$BUNDLE" --output-path "$exported" 2>&1)"; then
        echo "Could not export diagnostics from $BUNDLE — skipping test-host output report. Output: $error"
        exit 0
    fi
    find "$exported" -name "$CAPTURE_NAME" >"$files" 2>/dev/null
fi

if [ ! -s "$files" ]; then
    echo "No test-host output captured in $BUNDLE."
    exit 0
fi

while IFS= read -r file; do
    echo "=== $file"
    echo "--- lines matching $PATTERN"
    grep -E "$PATTERN" "$file" || echo "(no matching lines)"
    echo "--- last $TAIL_LINES lines"
    tail -n "$TAIL_LINES" "$file"
done <"$files"
