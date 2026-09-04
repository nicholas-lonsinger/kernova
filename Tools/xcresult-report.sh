#!/usr/bin/env bash
# Reads an .xcresult bundle and prints the test verdict: the counts from the
# bundle's summary, each failing test with its failure messages — a case that
# failed an attempt and passed on the retry included, marked as such — and one
# verdict line. This is the repo's one xcresult parse: `make check` and
# .github/workflows/xcodebuild-test.yml both call it.
#
# Usage:
#   Tools/xcresult-report.sh [--path <bundle> | --from-log <log> | --latest] [--failures | --flaky]
#
#   --path <bundle>  an explicit bundle, e.g. a downloaded CI artifact
#   --from-log <log> the bundle an xcodebuild log names (its last `.xcresult`
#                    path), binding the report to that run
#   --latest         the newest bundle in this checkout's build arena, via
#                    Tools/derived-data-path.sh (the default)
#   --failures       print only the `=== <test>` blocks, uncapped, for tooling
#   --flaky          print only the identifiers of tests that failed an
#                    attempt and passed on retry, one per line, for tooling
#
# Output (default mode, stdout):
#   result=Failed total=3948 passed=3945 failed=3 skipped=0 xfail=0
#   === VMConfigurationTests/defaultsMatchTemplate()
#   KernovaTests/VMConfigurationTests.swift:42: Expectation failed: (config.cpuCount → 2) == 4
#   === ClipboardTests/roundTrip() (passed on retry)
#   ...
#   xcresult-report: verdict=failed total=3948 failed=3 flaky=1 path=<bundle>
#
# Exit codes, default mode:
#   0  passed, and at least one test ran
#   1  failed
#   2  no bundle resolved, or the bundle is unreadable
#   3  zero tests ran — an `-only-testing:` filter that matches nothing still
#      prints ** TEST SUCCEEDED **, so this is the failure xcodebuild omits
# The two tooling modes exit 0 whenever the bundle was readable and 2 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

mode=report
source=latest
arg=
while [ $# -gt 0 ]; do
    case "$1" in
        --path | --from-log)
            [ $# -ge 2 ] || { echo "xcresult-report.sh: $1 needs a value" >&2; exit 2; }
            [ "$1" = --path ] && source=path || source=log
            arg="$2"
            shift 2
            ;;
        --latest) source=latest; shift ;;
        --failures) mode=failures; shift ;;
        --flaky) mode=flaky; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "xcresult-report.sh: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

bundle=
# unreadable <reason>: the diagnostic goes to stderr, the verdict line stays on
# stdout so a caller reading the last line still gets one, and the exit is 2.
unreadable() {
    echo "xcresult-report.sh: $1" >&2
    [ "$mode" = report ] && printf 'xcresult-report: verdict=unreadable reason=%s path=%s\n' "$2" "${bundle:--}"
    exit 2
}

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"; }

case "$source" in
    path) bundle="$arg" ;;
    log)
        [ -r "$arg" ] || unreadable "cannot read log '$arg'" no-log
        bundle="$(strip_ansi <"$arg" | grep -oE '[^[:space:]"]+\.xcresult' | tail -1)"
        [ -n "$bundle" ] || unreadable "log '$arg' names no .xcresult bundle" no-bundle-in-log
        ;;
    latest)
        arena="$("$ROOT/Tools/derived-data-path.sh" 2>/dev/null)" \
            || unreadable "could not resolve this checkout's build arena" no-arena
        for candidate in "$arena"/Logs/Test/*.xcresult; do
            [ -d "$candidate" ] || continue
            if [ -z "$bundle" ] || [ "$candidate" -nt "$bundle" ]; then bundle="$candidate"; fi
        done
        [ -n "$bundle" ] || unreadable "no .xcresult under $arena/Logs/Test" no-bundle-in-arena
        ;;
esac
[ -d "$bundle" ] || unreadable "no result bundle at '$bundle'" no-bundle

command -v jq >/dev/null 2>&1 || unreadable "jq is required" no-jq
command -v xcrun >/dev/null 2>&1 || unreadable "xcrun is required (Xcode toolchain)" no-xcrun

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Keep xcresulttool's stderr: a rejected flag or a corrupt bundle otherwise
# degrades to a verdict with nothing to debug from.
fetch() {
    if ! xcrun xcresulttool get test-results "$1" --path "$bundle" --format json >"$tmp/$1.json" 2>"$tmp/err"; then
        unreadable "xcresulttool could not read '$bundle': $(tr '\n' ' ' <"$tmp/err")" xcresulttool-failed
    fi
}

# A retried case passes overall while one Repetition failed, so match on
# either: the masked attempt's message is the one worth reading. Recursive
# descent (`..`) keeps the parse independent of the tree's nesting.
failure_blocks() {
    jq -r '
        [ .. | objects
          | select(.nodeType? == "Test Case")
          | select(.result == "Failed"
                   or any(.children[]?; .nodeType == "Repetition" and .result == "Failed")) ]
        | .[]
        | "=== " + (.nodeIdentifier // .name)
          + (if .result == "Passed" then " (passed on retry)" else "" end) + "\n"
          + ( [ .. | objects | select(.nodeType? == "Failure Message")
                | ( .sourceLocation
                    | if . then .filePath + ":" + (.lineNumber | tostring) + ": " else "" end )
                  + .name ]
              | unique | join("\n") )
    ' "$tmp/tests.json" | sed "s#$ROOT/##g"
}

# A genuine flake failed at least one Repetition but still passed overall — a
# bundle-wide retry marks every passed test's repetitions "Passed", so this
# does not false-positive on the tests dragged through the retry. A test that
# failed every repetition is broken, not flaky, and `result == "Passed"`
# excludes it. Dedup on `.nodeIdentifier` (suite-qualified), not `.name`: two
# suites can share a test's display name.
flaky_ids() {
    jq -r '
        [ .. | objects
          | select(.nodeType? == "Test Case" and .result == "Passed")
          | select(any(.children[]?; .nodeType == "Repetition" and .result == "Failed"))
          | (.nodeIdentifier // .name) ]
        | unique[]
    ' "$tmp/tests.json"
}

case "$mode" in
    failures) fetch tests; failure_blocks; exit 0 ;;
    flaky) fetch tests; flaky_ids; exit 0 ;;
esac

fetch summary
fetch tests

counts="$(jq -r '[.result, .totalTestCount, .passedTests, .failedTests, .skippedTests, .expectedFailures]
                 | map(tostring) | join(" ")' "$tmp/summary.json" 2>/dev/null)"
read -r result total passed failed skipped xfail <<<"$counts"
case "$total" in
    '' | *[!0-9]*) unreadable "summary of '$bundle' carries no totalTestCount" no-counts ;;
esac

flaky="$(flaky_ids | grep -c .)"

printf 'result=%s total=%s passed=%s failed=%s skipped=%s xfail=%s\n' \
    "$result" "$total" "$passed" "$failed" "$skipped" "$xfail"

# Verdict-mode caps keep a mass failure readable: 40 blocks, 20 lines each,
# 400 characters a line. `--failures` is the uncapped form.
failure_blocks | awk -v cap=40 -v lines=20 -v width=400 '
    /^=== / { blocks++; n = 0; if (blocks > cap) next; print; next }
    blocks > cap { next }
    {
        n++
        if (n > lines) { if (n == lines + 1) print "  … (more in the result bundle)"; next }
        if (length($0) > width) $0 = substr($0, 1, width) " …"
        print
    }
    END { if (blocks > cap) printf "+%d more failing tests (--failures lists them all)\n", blocks - cap }
'

if [ "$total" -eq 0 ]; then
    verdict=no-tests status=3
elif [ "$failed" -gt 0 ] || [ "$result" = Failed ]; then
    verdict=failed status=1
else
    verdict=passed status=0
fi
printf 'xcresult-report: verdict=%s total=%s failed=%s flaky=%s path=%s\n' \
    "$verdict" "$total" "$failed" "$flaky" "$bundle"
exit "$status"
