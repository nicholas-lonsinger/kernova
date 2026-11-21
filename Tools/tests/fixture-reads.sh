#!/usr/bin/env bash
# Fixture tests for Tools/lib/fixture-reads.sh: which paths a suite's
# `# fixture reads:` header lines declare — none, one line, several — which
# misspellings of one fail, and that prose and a line below the header do not
# count.
#
# fixture reads: Tools/lib/fixture-reads.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/fixture-reads.sh
. "$ROOT/Tools/lib/fixture-reads.sh"

lines() { tr '\n' ' ' | sed 's/ $//'; }

# reads_of <header line>... — fixture_reads' output, one line, for a suite
# whose header holds the lines and whose body a reads line, or `error` with
# what it printed to stderr.
reads_of() {
    local file="$tmp/suite.sh" out
    {
        printf '#!/usr/bin/env bash\n# What the suite tests.\n'
        [ $# -eq 0 ] || printf '%s\n' "$@"
        printf '\nset -uo pipefail\n# fixture reads: below/the/header\n'
    } >"$file"
    if out=$(fixture_reads "$file" 2>"$tmp/err"); then
        printf '%s' "$out" | lines
    else
        printf 'error'
    fi
}

check "no reads" "$(reads_of)" ''
check "one line" "$(reads_of '# fixture reads: Tools/a.sh Tools/lib')" 'Tools/a.sh Tools/lib'
check "two lines, spaced" "$(reads_of '# fixture reads: Tools/a.sh  Makefile' '#' '# fixture reads: .githooks/pre-push')" \
    'Tools/a.sh Makefile .githooks/pre-push'
check "a typo in the word" "$(reads_of '# fixture read: Tools/a.sh')" error
check "a typo in the word names the line" "$(grep -c "'# fixture read: Tools/a.sh' is not" "$tmp/err")" 1
check "a capital" "$(reads_of '# Fixture reads: Tools/a.sh')" error
check "no space after the hash" "$(reads_of '#fixture reads: Tools/a.sh')" error
check "no path" "$(reads_of '# fixture reads:')" error
check "prose naming fixture reads mid-line" "$(reads_of '# what the fixture reads: none of it is parsed')" ''

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s fixture-reads: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
