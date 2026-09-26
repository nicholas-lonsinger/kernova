#!/usr/bin/env bash
# A `…ForTesting` name says a declaration exists for tests alone; the
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
# A declaration is a binding keyword followed by the name, with nothing before
# it on the line but attributes, modifiers, and the header of a type whose body
# it is declared in. Attributes and modifiers are not enumerated — an unlisted
# spelling would read as "no declaration here" and pass in silence. What is
# recognised instead is their shape: bare words, each attribute's arguments
# removed as a balanced pair, because those hold commas, strings and nested
# calls. A statement keyword there is what a binding inside an expression puts
# in front of the name, which is how `if let …ForTesting` and a `case let`
# pattern are told from a declaration; a call, a member access, a comment and a
# string reach the name by some route other than a binding keyword and
# whitespace.
#
# A `{` earlier on the line opened a scope, and which scope decides it: a type
# body holds members, so `struct A { var xForTesting = 0 }` declares a seam,
# while a function or closure body holds locals, so the binding in
# `func f() { let xForTesting = 1 }` is not one. Only a type header is stepped
# over, and a head holding a quote is not one: the brace belongs to a string,
# where the text around it is prose rather than code. Reading the brace instead
# of refusing every line that holds one is what keeps a seam flagged whether or
# not it shares a line with its type.
#
# A frame is DEBUG only when its active condition guarantees DEBUG: a `&&`
# chain, no `||`, with `DEBUG` as one bare term, parenthesised or not.
# `#if !DEBUG`, `#if DEBUG || X` and the `#else` arm of any `#if` are not —
# `#if DEBUG` is the one spelling a seam is gated with.
#
# The second gate runs over the files the first one skips. AppKit writes a
# window frame, a split position, and a toolbar configuration to
# `UserDefaults.standard` with no injection point, and under the app as test
# host that is the app's own domain — so test code that names the process-wide
# store reads and writes the state of the app the developer is running. A test's
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
# Line comments are stripped before matching, so prose may name what it forbids.
# A string literal is not stripped, and reads as a reference.
#
# Reports every finding before failing, so one run fixes them all, and fails
# on a scan that did not complete: a check whose whole value is that it cannot
# pass in silence must not pass when a file went unread.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# Test code, by the path convention the header states; each gate takes one side
# of it.
test_paths='(^|/)[^/]*(Tests|TestSupport)/'

# Seams only test code may call, as the third gate reads them.
test_only_calls='placeForTesting bindSessionForTesting beginSessionContextForTesting'

report() {
    local summary=$1 text=$2
    printf '%s\n' "$text" | while IFS= read -r line; do
        echo "check-test-seams: $line" >&2
    done
    echo >&2
    printf '%s %s\n' "$(printf '%s\n' "$text" | wc -l | tr -d ' ')" "$summary" >&2
}

findings=$(git ls-files '*.swift' \
    | grep -vE "$test_paths" \
    | tr '\n' '\0' \
    | xargs -0 awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

        # `(DEBUG)`, `(DEBUG` and `DEBUG)` are all the one term `DEBUG`: a
        # parenthesised condition splits across its `&&` separators.
        function unwrap(s) { s = trim(s); sub(/^\(+/, "", s); sub(/\)+$/, "", s); return trim(s) }

        # The condition holds DEBUG defined on every branch that reaches here.
        function guarantees_debug(cond,   n, terms, i) {
            sub(/\/\/.*$/, "", cond)
            if (cond ~ /\|\|/) return 0
            n = split(cond, terms, "&&")
            for (i = 1; i <= n; i++) if (unwrap(terms[i]) == "DEBUG") return 1
            return 0
        }

        function gated(   i) {
            for (i = 1; i <= depth; i++) if (frame[i]) return 1
            return 0
        }

        function without_arguments(s,   previous) {
            do { previous = s; sub(/\([^()]*\)/, "", s) } while (s != previous)
            return s
        }

        # A `{` on the line opened a scope. A type body holds members, so a
        # binding past it is a declaration; a function or closure body holds
        # locals, so one past that is not. Only a type header is stepped over.
        function inside_type_body(prefix,   head) {
            while (index(prefix, "{") > 0) {
                head = substr(prefix, 1, index(prefix, "{") - 1)
                if (index(head, "\"") > 0) return prefix
                if (head !~ /(^|[^A-Za-z0-9_])(struct|class|enum|actor|protocol|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[^{]*$/) return prefix
                prefix = substr(prefix, index(prefix, "{") + 1)
            }
            return prefix
        }

        # What is left in front of the binding keyword, once the arguments and
        # any type header are gone, is an attribute or a modifier.
        function declares(prefix,   words, n, i) {
            prefix = without_arguments(prefix)
            prefix = inside_type_body(prefix)
            if (prefix !~ /^([[:space:]]*@?[A-Za-z_][A-Za-z0-9_.]*)*[[:space:]]*$/) return 0
            n = split(prefix, words, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (words[i] in statement) return 0
            return 1
        }

        # A keyword is one only whole: `varyingForTesting` is not a `var`.
        # substr clamps a start below 1 and returns the first character, so a
        # keyword in column 1 is settled by position: there is nothing before
        # it, and asking substr would hand back its own first letter.
        function keyword_starts(line, start) {
            return start == 1 || substr(line, start - 1, 1) !~ /[A-Za-z0-9_.]/
        }

        function declaration(line,   offset, rest, start) {
            if (line ~ /^[[:space:]]*\/\//) return 0
            offset = 0
            rest = line
            while (match(rest, binding_name)) {
                start = offset + RSTART
                if (keyword_starts(line, start) && declares(substr(line, 1, start - 1))) return 1
                offset = start
                rest = substr(line, offset + 1)
            }
            return 0
        }

        BEGIN {
            binding_name = "(var|let|func|class|struct|enum|actor|protocol|typealias|case)[[:space:]]+`?[A-Za-z_][A-Za-z0-9_]*ForTesting"
            n = split("if guard while for switch else do catch repeat defer return throw in await try as is where case", words, " ")
            for (k = 1; k <= n; k++) statement[words[k]] = 1
        }

        FNR == 1 {
            if (NR > 1 && depth != 0) printf "%s — %d #if block(s) left open\n", previous, depth
            depth = 0
        }
        { previous = FILENAME }

        /^[[:space:]]*#if[[:space:](]/ {
            condition = $0; sub(/^[[:space:]]*#if[[:space:]]*/, "", condition)
            frame[++depth] = guarantees_debug(condition)
            next
        }
        /^[[:space:]]*#elseif[[:space:](]/ {
            condition = $0; sub(/^[[:space:]]*#elseif[[:space:]]*/, "", condition)
            if (depth) frame[depth] = guarantees_debug(condition)
            next
        }
        /^[[:space:]]*#else([[:space:]]|$)/  { if (depth) frame[depth] = 0; next }
        /^[[:space:]]*#endif([[:space:]]|$)/ { if (depth) depth--; next }

        declaration($0) && !gated() {
            printf "%s:%d — %s\n", FILENAME, FNR, trim($0)
        }

        END { if (depth != 0) printf "%s — %d #if block(s) left open\n", previous, depth }
    ')
scan_status=$?

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
    report 'test-seam finding(s): a ForTesting declaration outside #if DEBUG, or a file whose #if blocks do not close' \
        "$findings"
fi

if [ -n "$store_findings" ]; then
    report 'test-store finding(s): test code reaching the process-wide UserDefaults instead of a store of its own' \
        "$store_findings"
fi

if [ -n "$call_findings" ]; then
    report 'test-only-call finding(s): code outside a test target naming a seam only tests may call' \
        "$call_findings"
fi

for scan in "$scan_status" "$store_scan_status" "$call_scan_status"; do
    if [ "$scan" -ne 0 ]; then
        echo "check-test-seams: a scan exited $scan — at least one tracked Swift file went unread, so a finding in it would not appear above" >&2
        exit 1
    fi
done

if [ -n "$findings" ] || [ -n "$store_findings" ] || [ -n "$call_findings" ]; then
    exit 1
fi

pass "test seams: every ForTesting declaration is inside #if DEBUG"
pass "test stores: no test reaches the process-wide UserDefaults"
pass "test-only calls: no code outside a test target calls a seam only tests may call"
