#!/usr/bin/env bash
# Fixture tests for Tools/lib/lint-inputs.sh: which tracked paths each lint
# step takes, at the root, nested and in .githooks; how a check's
# `# make lint:` header line orders it — each valid value, a typo in the value,
# a typo in the prefix, a missing reason, and the line below the header; and
# which paths a suite's `# fixture reads:` header lines declare, and which
# misspellings of one fail.

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
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"
# shellcheck source=../lib/lint-inputs.sh
. "$ROOT/Tools/lib/lint-inputs.sh"

# ---- the paths each step takes --------------------------------------------------

repo="$tmp/repo"
git init -q -b main "$repo"
for path in \
    root.sh deep/a/b.sh installer.command deep/installer.command notes.txt \
    .githooks/pre-push .githooks/commit-msg \
    Tools/check-one.sh Tools/check-two.sh Tools/sub/check-nested.sh Tools/checker.sh \
    Tools/tests/suite.sh Tools/tests/fixtures/data.sh \
    .agents/skills/alpha/tests/run.sh .agents/skills/beta/tests/other.sh .agents/skills/alpha/tests/deep/run.sh; do
    mkdir -p "$repo/$(dirname "$path")"
    printf '#!/bin/bash\n' >"$repo/$path"
done
git -C "$repo" add -A
printf '#!/bin/bash\n' >"$repo/untracked.sh"

lines() { tr '\n' ' ' | sed 's/ $//'; }
in_repo() { (cd "$repo" && "$@") | sort | lines; }

check "shell sources" "$(in_repo lint_shell_sources)" \
    "$(printf '%s\n' .agents/skills/alpha/tests/deep/run.sh .agents/skills/alpha/tests/run.sh .agents/skills/beta/tests/other.sh \
        .githooks/commit-msg .githooks/pre-push Tools/check-one.sh Tools/check-two.sh Tools/checker.sh Tools/sub/check-nested.sh \
        Tools/tests/fixtures/data.sh Tools/tests/suite.sh deep/a/b.sh deep/installer.command \
        installer.command root.sh | sort | lines)"
check "checks" "$(in_repo lint_checks)" 'Tools/check-one.sh Tools/check-two.sh'
check "fixture suites" "$(in_repo lint_fixture_suites)" '.agents/skills/alpha/tests/run.sh Tools/tests/suite.sh'

# ---- a check's order --------------------------------------------------------------

# order_of <header line> [<line below the header>] — lint_order's output and
# status for a check whose header holds the first line and whose body the
# second, or `error` with what it printed to stderr.
order_of() {
    local file="$tmp/check.sh" out
    {
        printf '#!/usr/bin/env bash\n# What the check guards.\n'
        [ -z "$1" ] || printf '%s\n' "$1"
        printf '#\n# Usage: Tools/check.sh\n\nset -uo pipefail\n'
        [ -z "${2:-}" ] || printf '%s\n' "$2"
    } >"$file"
    if out=$(lint_order "$file" 2>"$tmp/err"); then
        printf '%s' "$out"
    else
        printf 'error'
    fi
}

check "no line" "$(order_of '')" first
check "runs last" "$(order_of '# make lint: runs last — it builds a tool')" last
check "not run" "$(order_of '# make lint: not run — CI runs it')" not-run
check "a typo in the value" "$(order_of '# make lint: run last — it builds a tool')" error
check "a typo in the value names the line" "$(grep -c "'# make lint: run last — it builds a tool' is not" "$tmp/err")" 1
check "no reason" "$(order_of '# make lint: runs last')" error
check "a hyphen for the dash" "$(order_of '# make lint: not run - CI runs it')" error
check "a typo in the prefix leaves the check running" "$(order_of '# make-lint: not run — CI runs it')" first
check "a line below the header does not count" "$(order_of '' '# make lint: not run — CI runs it')" first

# ---- a suite's reads --------------------------------------------------------------

# reads_of <header line>... — lint_fixture_reads' output, one line, for a suite
# whose header holds the lines and whose body a reads line, or `error` with
# what it printed to stderr.
reads_of() {
    local file="$tmp/suite.sh" out
    {
        printf '#!/usr/bin/env bash\n# What the suite tests.\n'
        [ $# -eq 0 ] || printf '%s\n' "$@"
        printf '\nset -uo pipefail\n# fixture reads: below/the/header\n'
    } >"$file"
    if out=$(lint_fixture_reads "$file" 2>"$tmp/err"); then
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
    printf '  %s✓%s lint-inputs: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
