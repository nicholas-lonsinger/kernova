#!/usr/bin/env bash
# Runs one Makefile target — build, build-for-testing, test,
# test-without-building, test-suite, or lint — with the whole xcodebuild
# stream captured to a file, and prints only the verdict: counts from the
# result bundle, deduplicated compile errors, failing tests with their
# messages, and the log and bundle paths.
#
# Usage:
#   Tools/check.sh build | build-for-testing | test | test-without-building | lint
#   Tools/check.sh test-suite <Target/Suite>
#   Tools/check.sh --from-log <file> <target> [<Target/Suite>]
#   make check [WHAT=<target>] [SUITE=<Target/Suite>]
#
# `--from-log` reports an existing log and runs nothing. Otherwise the target
# runs synchronously in the foreground with no timeout, poll, or retry of its
# own: run this script in the background and let the harness's exit
# notification be the completion signal. The log lands in artifacts/check/
# (KERNOVA_CHECK_DIR overrides) beside a copy of the verdict.
#
# Output (stdout, nothing else):
#   check: target=test suite=- duration=412s log=artifacts/check/test.log
#   result=Failed total=3948 passed=3945 failed=3 skipped=0 xfail=0
#   === VMConfigurationTests/defaultsMatchTemplate()
#   VMConfigurationTests.swift:42: Expectation failed: (config.cpuCount → 2) == 4
#   errors:                            (build-failed and lint-failed only)
#     Kernova/Services/VMSession.swift:42:9: error: cannot find 'foo' in scope
#   check: verdict=test-failed target=test suite=- total=3948 failed=3 flaky=0 log=… xcresult=…
#
# Verdict tokens and exit codes:
#   0  green         the target succeeded; a test target ran at least one test
#   1  test-failed   tests ran and some failed (or the run died after testing)
#   2  build-failed  xcodebuild did not complete the build
#   3  no-tests-ran  the run passed but executed zero tests: the SUITE= filter
#                    matched nothing, which xcodebuild reports as a success
#   4  lint-failed   `make lint` reported findings
#   5  setup-error   bad usage, xcodebuild missing, or the log or bundle unreadable

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 5

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

target=
suite=
from_log=
if [ "${1:-}" = --from-log ]; then
    from_log="${2:-}"
    shift 2 2>/dev/null || true
fi
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
    usage
    exit 0
fi
target="${1:-}"
suite="${2:-}"

setup_error() {
    echo "check.sh: $1" >&2
    printf 'check: verdict=setup-error reason=%s target=%s suite=%s\n' "$2" "${target:--}" "${suite:--}"
    exit 5
}

case "$target" in
    build | build-for-testing | test | test-without-building | test-suite | lint) ;;
    '') usage; setup_error "a target is required" usage ;;
    *) usage; setup_error "unknown target '$target'" usage ;;
esac
if [ "$target" = test-suite ]; then
    [ -n "$suite" ] || setup_error "test-suite needs <Target/Suite>, e.g. KernovaTests/VMConfigurationTests" usage
elif [ -n "$suite" ]; then
    setup_error "a suite applies to test-suite only" usage
fi
[ $# -le 2 ] || setup_error "too many arguments" usage

out_dir="${KERNOVA_CHECK_DIR:-artifacts/check}"

# ---- run ------------------------------------------------------------------

if [ -n "$from_log" ]; then
    [ -r "$from_log" ] || setup_error "cannot read log '$from_log'" no-log
    log="$from_log"
    duration=-
    # make's own failure line is the exit status the log preserved.
    if grep -qE '^make(\[[0-9]+\])?: \*\*\* ' "$log"; then make_status=2; else make_status=0; fi
else
    if [ "$target" != lint ] && ! command -v xcodebuild >/dev/null 2>&1; then
        setup_error "xcodebuild not found — install Xcode and run \`make doctor\`" xcodebuild-missing
    fi
    mkdir -p "$out_dir" || setup_error "cannot create '$out_dir'" no-out-dir
    log="$out_dir/$target.log"
    start="$(date +%s)"
    if [ -n "$suite" ]; then
        make "$target" "SUITE=$suite" >"$log" 2>&1
    else
        make "$target" >"$log" 2>&1
    fi
    make_status=$?
    duration="$(( $(date +%s) - start ))s"
fi

# ---- read the log ---------------------------------------------------------

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"; }
clean_log() { strip_ansi <"$log"; }

build_failed() {
    clean_log | grep -qE '^\*\* [A-Z ]*BUILD FAILED \*\*|^The following build commands failed:'
}

# Compiler, linker, and driver errors, deduplicated (xcodebuild repeats each
# in its closing summary) and rewritten repo-relative.
compile_errors() {
    clean_log \
        | grep -E '^[[:space:]]*(/[^:]+:[0-9]+(:[0-9]+)?: error: |(xcodebuild|clang|swiftc|swift): error: |ld: |error: )' \
        | sed -E "s/^[[:space:]]+//; s#$ROOT/##g" \
        | awk '!seen[$0]++'
}

# Every linter in `make lint` names its findings differently; this is the
# union of their line shapes.
lint_findings() {
    clean_log \
        | grep -E 'error: |warning: |✗|^In .* line [0-9]+:|SC[0-9]{4}|^lint: ' \
        | sed -E "s#$ROOT/##g" \
        | awk '!seen[$0]++'
}

# Print a titled, capped section: section <title> <cap> < lines
section() {
    awk -v title="$1" -v cap="$2" '
        NR == 1 { print title ":" }
        NR <= cap { print "  " $0; next }
        END { if (NR > cap) printf "  +%d more (see log)\n", NR - cap }
    '
}

tail_section() {
    printf 'tail:\n'
    clean_log | tail -n 20 | sed 's/^/  /'
}

# ---- classify -------------------------------------------------------------

verdict=
status=0
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
extra=""
xcresult="-"

case "$target" in
    lint)
        if [ "$make_status" -eq 0 ]; then
            verdict=green
        else
            verdict=lint-failed status=4
            findings="$(lint_findings)"
            if [ -n "$findings" ]; then
                printf '%s\n' "$findings" | section errors 40 >>"$body"
            else
                tail_section >>"$body"
            fi
        fi
        ;;
    build | build-for-testing)
        if [ "$make_status" -eq 0 ] && ! build_failed; then
            verdict=green
        else
            verdict=build-failed status=2
            errors="$(compile_errors)"
            if [ -n "$errors" ]; then
                printf '%s\n' "$errors" | section errors 20 >>"$body"
            else
                tail_section >>"$body"
            fi
        fi
        ;;
    *)
        if build_failed; then
            verdict=build-failed status=2
            errors="$(compile_errors)"
            if [ -n "$errors" ]; then
                printf '%s\n' "$errors" | section errors 20 >>"$body"
            else
                tail_section >>"$body"
            fi
        else
            report="$(mktemp)"
            "$ROOT/Tools/xcresult-report.sh" --from-log "$log" >"$report" 2>"$report.err"
            report_status=$?
            last="$(tail -n 1 "$report")"
            case "$report_status" in
                2)
                    if [ "$make_status" -eq 0 ]; then
                        reason="$(sed -n 's/.* reason=\([^ ]*\).*/\1/p' <<<"$last")"
                        rm -f "$report" "$report.err"
                        setup_error "$(cat "$report.err" 2>/dev/null || true)" "${reason:-no-result-bundle}"
                    fi
                    verdict=test-failed status=1
                    extra=" reason=no-result-bundle"
                    tail_section >>"$body"
                    ;;
                *)
                    sed '$d' "$report" >>"$body"
                    xcresult="$(sed -n 's/.* path=//p' <<<"$last")"
                    extra=" $(sed -E 's/^xcresult-report: verdict=[^ ]* //; s/ path=.*$//' <<<"$last")"
                    case "$report_status" in
                        3) verdict=no-tests-ran status=3 ;;
                        1) verdict=test-failed status=1 ;;
                        0)
                            if [ "$make_status" -eq 0 ]; then
                                verdict=green
                            else
                                verdict=test-failed status=1
                                extra="$extra reason=make-exit-$make_status"
                                tail_section >>"$body"
                            fi
                            ;;
                    esac
                    ;;
            esac
            rm -f "$report" "$report.err"
        fi
        ;;
esac

# ---- report ---------------------------------------------------------------

{
    printf 'check: target=%s suite=%s duration=%s log=%s\n' "$target" "${suite:--}" "$duration" "$log"
    cat "$body"
    printf 'check: verdict=%s target=%s suite=%s%s log=%s xcresult=%s\n' \
        "$verdict" "$target" "${suite:--}" "$extra" "$log" "$xcresult"
} >"$body.out"
if [ -z "$from_log" ]; then
    cp "$body.out" "$out_dir/$target.verdict" 2>/dev/null || true
fi
cat "$body.out"
rm -f "$body.out"
exit "$status"
