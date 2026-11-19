#!/usr/bin/env bash
# Lints the checkout: the command `make lint` runs and records for
# `make attest`. Stops at the first failing step, in this order, cheapest
# first so an obvious finding surfaces without waiting on a tool build:
#
#   1. `bash -n`, then shellcheck, over the tracked shell scripts, the guest
#      agent's .command installers, and the git hooks.
#   2. Every tracked Tools/check-*.sh, with no arguments.
#   3. swift-format lint --strict over the roots Tools/lib/swift-roots.sh names.
#   4. The fixture suites, through Tools/tests/git-isolation.sh: every tracked
#      Tools/tests/*.sh but that runner, and every .agents/skills/*/tests/run.sh.
#      A suite needs no Xcode and runs in seconds, which is what lets lint and
#      the pre-push hook gate it; the dead-code tool's swift-syntax, which each
#      checkout builds once in about 15 s, is the exception.
#   5. The checks whose header declares `# make lint: runs last — <why>`.
#
# A check that reads a built product rather than the checkout declares
# `# make lint: not run — <who runs it>` instead. Any other value of that line
# fails the lint, so a typo cannot drop a check.
#
# `bash -n` is not redundant with shellcheck: under macOS's bash 3.2 it rejects
# `|&` and `&>>`, which shellcheck 0.11 accepts.

set -uo pipefail

# A fixture suite that runs make must not inherit -n, -i or -k from the make
# that ran this.
unset MAKEFLAGS MFLAGS MAKELEVEL

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/swift-roots.sh
. Tools/lib/swift-roots.sh

die() { echo "lint: $1" >&2; exit 1; }

# tracked <glob>... — the tracked paths matching any glob, where `*` stops at
# a `/` and `**/` spans directories.
tracked() {
    local pathspecs=() glob
    for glob in "$@"; do pathspecs+=(":(glob)$glob"); done
    git ls-files -- "${pathspecs[@]}"
}

# ---- 1. shell ------------------------------------------------------------------

shell_sources=()
while IFS= read -r f; do shell_sources+=("$f"); done < <(tracked '**/*.sh' '**/*.command' '.githooks/*')
[ "${#shell_sources[@]}" -gt 0 ] || die 'git tracks no shell scripts — not a git checkout?'
for f in "${shell_sources[@]}"; do bash -n "$f" || exit 1; done
command -v shellcheck >/dev/null 2>&1 || die 'shellcheck is not installed — `make setup` installs it'
shellcheck "${shell_sources[@]}" || exit 1
pass "shell: bash -n and shellcheck over ${#shell_sources[@]} scripts"

# ---- the checks, sorted by their declared order ------------------------------------

first_checks=()
last_checks=()
not_run=()
while IFS= read -r check; do
    declared=$(grep -m 1 '^# make lint:' "$check")
    case "$declared" in
        '') first_checks+=("$check") ;;
        '# make lint: runs last — '?*) last_checks+=("$check") ;;
        '# make lint: not run — '?*) not_run+=("$check") ;;
        *) die "$check: '$declared' is not '# make lint: runs last — <why>' or '# make lint: not run — <who runs it>'" ;;
    esac
done < <(tracked 'Tools/check-*.sh')
[ "${#first_checks[@]}" -gt 0 ] || die 'git tracks no Tools/check-*.sh — not a git checkout?'

# ---- 2. the checks that read the checkout ----------------------------------------

for check in "${first_checks[@]}"; do bash "$check" || exit 1; done

# ---- 3. Swift --------------------------------------------------------------------

swift=()
while IFS= read -r root; do swift+=("$root"); done < <(swift_roots)
[ "${#swift[@]}" -gt 0 ] || die 'git tracks no Swift sources — not a git checkout?'
xcrun swift-format lint --strict --parallel --recursive "${swift[@]}" || exit 1
pass "swift-format: ${#swift[@]} roots"

# ---- 4. fixture suites -----------------------------------------------------------

runner=Tools/tests/git-isolation.sh
suites=()
while IFS= read -r suite; do
    [ "$suite" = "$runner" ] || suites+=("$suite")
done < <(tracked 'Tools/tests/*.sh' '.agents/skills/*/tests/run.sh')
[ "${#suites[@]}" -gt 0 ] || die 'git tracks no fixture suites — not a git checkout?'
bash "$runner" "${suites[@]}" || exit 1

# ---- 5. the checks that run last -------------------------------------------------

for check in ${last_checks[@]+"${last_checks[@]}"}; do bash "$check" || exit 1; done

[ "${#not_run[@]}" -eq 0 ] || detail "not run, as their headers say: ${not_run[*]}"
