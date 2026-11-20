#!/usr/bin/env bash
# A name containing `ForTesting` says a declaration exists for tests alone; the
# `#if DEBUG` around it is what makes that true. Ungated, it compiles, links,
# and ships in a Release build, and nothing else in the toolchain objects — the
# compiler only rejects an ungated *reference* to a gated declaration, never an
# ungated declaration. This check is where the gate is required.
#
# Scope is every tracked Swift file outside a test target: a path with a
# directory component ending in `Tests` or `TestSupport` is test code, where a
# `ForTesting` name never reaches a shipped binary. A test root named off that
# convention is scanned instead of skipped, so the gap is loud rather than
# silent.
#
# `dead-code-sources ungated-seams` parses as Swift each file whose text
# contains `ForTesting`. What counts as a seam, and which `#if` gates one, is
# `DebugOnlyCode`'s (Tools/DeadCode). The dead-code scan leaves debug-only code
# out of what only tests reach by the same reading, so a seam this check passes
# is never listed as reached only by tests; one that nothing uses is listed as
# dead. `#if DEBUG` is the one spelling a seam is gated with.
#
# The second gate runs over the files the first one skips. AppKit writes a
# window frame, a split position, and a toolbar configuration to
# `UserDefaults.standard` with no injection point, and in the test host that
# domain outlives the run — so test code that names the process-wide store
# reads what an earlier run left and leaves its own for the next. A test's
# own defaults are a `MemoryUserDefaults`, and a window that should persist
# nothing takes `WindowAutosaveScope.unsaved()`. Both spellings of the
# process-wide store are the finding, `UserDefaults.standard` and
# `UserDefaults()`; `UserDefaults(suiteName:)` names a store of the caller's own
# and is not one.
#
# The third gate runs over the first one's files. Most seams are reached from
# app code by design — a hook it invokes, a task it hands out — but one that
# skips a rule the app must obey is reached by tests alone: `placeForTesting`
# places a lifecycle phase past every rule a transition obeys. The compiler
# cannot refuse an app-code call — CI builds only Debug, and a call inside
# `#if DEBUG` compiles in every configuration — so this check does. Such a name
# is listed in `test_only_calls`, and outside test code it may appear only in
# its own `func` declaration.
#
# The fourth gate runs over the second one's files. A test case's admission and
# its scratch removal come from the `.caseScoped` trait, and a case outside it
# has neither: a `TestScratchDirectory` it mints stops the process. A nested
# suite inherits the trait, so the finding is a top-level `@Suite` attribute —
# one starting a line, alone or after other attributes, read to its closing
# parenthesis — that does not name it. A test target that builds where
# `KernovaTestSupport` does not, `unscoped_test_roots`, has no trait to name and
# cannot mint scratch, so the gate skips it.
#
# The fifth gate runs over the second one's files too. The temporary directory
# is shared by every test, so what a test leaves there outlives it and piles up
# run after run. A `TestScratchDirectory` is removed when the case that minted it ends,
# whatever still holds it, so test code reaches the temporary directory only
# through that owner — or, in `unscoped_test_roots`, which cannot reach it,
# through `PortableScratchDirectory`. Their files and the first one's own test,
# `scratch_owners`, are the only places the spellings may appear: `temporaryDirectory`,
# `NSTemporaryDirectory`, `itemReplacementDirectory` and `TMPDIR`, each as a
# whole word.
#
# Line comments are stripped before matching, so prose may name what it forbids.
# A string literal is not stripped, and reads as a reference.
#
# Reports every finding before failing, so one run fixes them all, and fails
# on a scan that did not complete: a check whose whole value is that it cannot
# pass in silence must not pass when a file went unread.
#
# make lint: runs last — a cold tool cache builds dead-code-sources in release (minutes)

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# Test code, by the path convention the header states; each gate takes one side
# of it.
test_paths='(^|/)[^/]*(Tests|TestSupport)/'

# Seams only test code may call, as the third gate reads them.
test_only_calls='placeForTesting bindSessionForTesting beginSessionContextForTesting fixtureForTesting'

# The test files that may name the temporary directory, as the fifth gate
# reads them: the owner and its own test.
scratch_owners='KernovaKit/Sources/KernovaTestSupport/TestScratchDirectory.swift KernovaKit/Tests/KernovaKitTests/TestScratchDirectoryTests.swift KernovaKit/Sources/KernovaPortableTestSupport/PortableScratchDirectory.swift'

# The test targets the fourth gate skips, as its header paragraph reads them.
unscoped_test_roots='^(KernovaKit/Tests/(KernovaPortableTests|KernovaWireTests|KernovaContainerTests|KernovaAgentCoreTests|KernovaAgentRuntimeTests|KernovaDBusTests|KernovaPlatformLinuxTests|KernovaLinuxAgentTests|KernovaFileTreeTests|KernovaTreeTransferTests|KernovaItemTransferTests|KernovaAgentInstallTests)|Tools/DeadCode/Tests)/'

report() {
    local summary=$1 text=$2
    printf '%s\n' "$text" | while IFS= read -r line; do
        echo "check-test-seams: $line" >&2
    done
    echo >&2
    printf '%s %s\n' "$(printf '%s\n' "$text" | wc -l | tr -d ' ')" "$summary" >&2
}

if seam_tool=$("$lib_dir/install-dead-code-tool.sh" dead-code-sources); then
    findings=$(git ls-files '*.swift' \
        | grep -vE "$test_paths" \
        | tr '\n' '\0' \
        | xargs -0 "$seam_tool" ungated-seams)
    scan_status=$?
else
    echo 'check-test-seams: dead-code-sources does not install, so the seam gate read no file' >&2
    findings=''
    scan_status=1
fi

store_findings=$(git ls-files '*.swift' \
    | grep -E "$test_paths" \
    | tr '\n' '\0' \
    | xargs -0 awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

        {
            code = $0
            sub(/\/\/.*$/, "", code)
            if (code ~ /(^|[^A-Za-z0-9_])UserDefaults[[:space:]]*(\.[[:space:]]*standard($|[^A-Za-z0-9_])|\([[:space:]]*\))/) {
                printf "%s:%d — %s\n", FILENAME, FNR, trim(code)
            }
        }
    ')
store_scan_status=$?

suite_findings=$(git ls-files '*.swift' \
    | grep -E "$test_paths" \
    | grep -vE "$unscoped_test_roots" \
    | tr '\n' '\0' \
    | xargs -0 awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

        function settle() {
            if (attribute !~ /(^|[^A-Za-z0-9_])\.caseScoped([^A-Za-z0-9_]|$)/) {
                printf "%s:%d — %s\n", file, start, trim(first)
            }
            reading = 0
        }

        FNR == 1 { if (reading) settle() }

        {
            code = $0
            sub(/\/\/.*$/, "", code)
            if (!reading) {
                if (code !~ /^(@[A-Za-z_][A-Za-z0-9_.]*(\([^()]*\))?[[:space:]]+)*@Suite([^A-Za-z0-9_]|$)/) next
                reading = 1; attribute = ""; depth = 0; opened = 0
                file = FILENAME; start = FNR; first = code
            }
            attribute = attribute " " code
            opens = gsub(/\(/, "(", code)
            closes = gsub(/\)/, ")", code)
            depth += opens - closes
            if (opens) opened = 1
            if (!opened || depth <= 0) settle()
        }

        END { if (reading) settle() }
    ')
suite_scan_status=$?

scratch_findings=$(git ls-files '*.swift' \
    | grep -E "$test_paths" \
    | grep -vxF -f <(tr ' ' '\n' <<<"$scratch_owners") \
    | tr '\n' '\0' \
    | xargs -0 awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

        {
            code = $0
            sub(/\/\/.*$/, "", code)
            if (code ~ /(^|[^A-Za-z0-9_])(temporaryDirectory|NSTemporaryDirectory|itemReplacementDirectory|TMPDIR)([^A-Za-z0-9_]|$)/) {
                printf "%s:%d — %s\n", FILENAME, FNR, trim(code)
            }
        }
    ')
scratch_scan_status=$?

call_findings=$(git ls-files '*.swift' \
    | grep -vE "$test_paths" \
    | tr '\n' '\0' \
    | xargs -0 awk -v names="$test_only_calls" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

        BEGIN { gsub(/[[:space:]]+/, "|", names) }

        {
            code = $0
            sub(/\/\/.*$/, "", code)
            if (code !~ "(^|[^A-Za-z0-9_])(" names ")([^A-Za-z0-9_]|$)") next
            if (code ~ "(^|[^A-Za-z0-9_])func[[:space:]]+(" names ")([^A-Za-z0-9_]|$)") next
            printf "%s:%d — %s\n", FILENAME, FNR, trim(code)
        }
    ')
call_scan_status=$?

if [ -n "$findings" ]; then
    report 'test-seam finding(s): a ForTesting declaration a Release build compiles, outside #if DEBUG' \
        "$findings"
fi

if [ -n "$store_findings" ]; then
    report 'test-store finding(s): test code reaching the process-wide UserDefaults instead of a store of its own' \
        "$store_findings"
fi

if [ -n "$suite_findings" ]; then
    report 'test-scope finding(s): a top-level @Suite without the .caseScoped trait, whose cases run unadmitted and cannot mint scratch' \
        "$suite_findings"
fi

if [ -n "$scratch_findings" ]; then
    report 'test-scratch finding(s): test code building a path under the process-wide temporary directory instead of a TestScratchDirectory' \
        "$scratch_findings"
fi

if [ -n "$call_findings" ]; then
    report 'test-only-call finding(s): code outside a test target naming a seam only tests may call' \
        "$call_findings"
fi

for scan in "$scan_status" "$store_scan_status" "$suite_scan_status" "$scratch_scan_status" "$call_scan_status"; do
    if [ "$scan" -ne 0 ]; then
        echo "check-test-seams: a scan exited $scan — at least one tracked Swift file went unread, so a finding in it would not appear above" >&2
        exit 1
    fi
done

if [ -n "$findings" ] || [ -n "$store_findings" ] || [ -n "$suite_findings" ] || [ -n "$scratch_findings" ] \
    || [ -n "$call_findings" ]; then
    exit 1
fi

pass "test seams: every ForTesting declaration is inside #if DEBUG"
pass "test stores: no test reaches the process-wide UserDefaults"
pass "test scopes: every top-level @Suite carries the .caseScoped trait"
pass "test scratch: every test path under the temporary directory comes from TestScratchDirectory"
pass "test-only calls: no code outside a test target calls a seam only tests may call"
