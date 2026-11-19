#!/usr/bin/env bash
# Lints the checkout: what `Tools/attest.sh record lint` runs, for
# `make lint`. Stops at the first failing step, in this order, cheapest first
# so an obvious finding surfaces without waiting on a tool build:
#
#   1. `bash -n`, then shellcheck, over the tracked shell scripts, the guest
#      agent's .command installers, and the git hooks.
#   2. Every tracked Tools/check-*.sh that declares no order, with no arguments.
#   3. swift-format lint --strict over the roots Tools/lib/swift-roots.sh names.
#   4. The fixture suites, through Tools/tests/git-isolation.sh. A suite needs
#      no Xcode and runs in seconds, which is what lets lint and the pre-push
#      hook gate it; the dead-code tool's swift-syntax, which each checkout
#      builds once in about 15 s, is the exception.
#   5. The checks whose header declares `# make lint: runs last — <why>`.
#
# Tools/lib/lint-inputs.sh lists each step's files and reads a check's order
# from its header; a check that reads a built product declares
# `# make lint: not run — <who runs it>` there.

set -uo pipefail

# What the caller's environment would otherwise change about the verdict:
# make's flags, which a fixture suite that runs make inherits; option
# variables shellcheck, grep and perl read; a file bash sources before every
# script; a toolchain override xcrun honours; and git's repository variables.
unset MAKEFLAGS MFLAGS MAKELEVEL SHELLCHECK_OPTS GREP_OPTIONS PERL5OPT BASH_ENV ENV TOOLCHAINS
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/swift-roots.sh
. Tools/lib/swift-roots.sh
# shellcheck source=lib/lint-inputs.sh
. Tools/lib/lint-inputs.sh

die() { echo "lint: $1" >&2; exit 1; }

# ---- 1. shell ------------------------------------------------------------------

shell_sources=()
while IFS= read -r f; do shell_sources+=("$f"); done < <(lint_shell_sources)
[ "${#shell_sources[@]}" -gt 0 ] || die 'git tracks no shell scripts — not a git checkout?'
# macOS's own bash 3.2, whatever bash is first on PATH: it rejects `|&` and
# `&>>`, which shellcheck 0.11 accepts, and it is the bash a script's
# `#!/usr/bin/env bash` meets on a Mac with nothing installed.
for f in "${shell_sources[@]}"; do /bin/bash -n "$f" || exit 1; done
command -v shellcheck >/dev/null 2>&1 || die 'shellcheck is not installed — `make setup` installs it'
shellcheck "${shell_sources[@]}" || exit 1
pass "shell: /bin/bash -n and shellcheck over ${#shell_sources[@]} scripts"

# ---- the checks, sorted by their declared order ------------------------------------

first_checks=()
last_checks=()
not_run=()
while IFS= read -r check; do
    order=$(lint_order "$check") || exit 1
    case "$order" in
        first) first_checks+=("$check") ;;
        last) last_checks+=("$check") ;;
        not-run) not_run+=("$check") ;;
    esac
done < <(lint_checks)
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

suites=()
while IFS= read -r suite; do suites+=("$suite"); done < <(lint_fixture_suites)
[ "${#suites[@]}" -gt 0 ] || die 'git tracks no fixture suites — not a git checkout?'
bash Tools/tests/git-isolation.sh "${suites[@]}" || exit 1

# ---- 5. the checks that run last -------------------------------------------------

for check in ${last_checks[@]+"${last_checks[@]}"}; do bash "$check" || exit 1; done

[ "${#not_run[@]}" -eq 0 ] || detail "not run, as their headers say: ${not_run[*]}"
