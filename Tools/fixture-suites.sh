#!/usr/bin/env bash
# Lint's fixture step: runs the suites given as arguments through
# Tools/tests/git-isolation.sh, unless a pass of the same suites is recorded
# for the same tooling.
#
#     Tools/fixture-suites.sh <suite, relative to the repo root>...
#
# A pass is recorded (Tools/lib/attest-records.sh) under the suites, the tree
# of the tooling surface — what `git add -A` would stage under the paths
# tooling_surface names — the Xcode and macOS builds, and the bash and git PATH
# resolves. It is recorded only when every suite passed, the surface is the
# same after the run as before, and it holds no untracked file: a suite lists
# its inputs from git and reads them from disk, so an untracked file would be
# keyed without being read.
#
# A suite reading a file outside the surface can reuse a pass that file no
# longer earns. CI's record store starts empty, so CI runs every suite.

set -uo pipefail

# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/attest-records.sh
. Tools/lib/attest-records.sh

[ $# -gt 0 ] || { echo 'usage: Tools/fixture-suites.sh <suite>...' >&2; exit 2; }

# tooling_surface <tree> — the paths in <tree> a fixture suite may read: the
# tooling directories, the Makefile, and the root's dotfiles, which tools find
# by searching upward.
tooling_surface() {
    printf '%s\n' Tools .githooks .agents Makefile
    git ls-tree "$1" | awk -F '\t' '$1 ~ / blob / && $2 ~ /^\./ { print $2 }'
}

# fixture_inputs <tree> <suite>... — the lines a pass of the suites over the
# content tree <tree> is recorded under.
fixture_inputs() {
    local tree=$1 scratch surface status machine bash git
    shift
    scratch=$(mktemp -d) || return 1
    # shellcheck disable=SC2046 # one path per word
    surface=$(git ls-tree -r --full-tree "$tree" -- $(tooling_surface "$tree") |
        GIT_INDEX_FILE="$scratch/index" git update-index --index-info &&
        GIT_INDEX_FILE="$scratch/index" git write-tree)
    status=$?
    rm -rf "$scratch"
    [ "$status" -eq 0 ] || return 1
    machine=$(machine_lines) || return 1
    bash=$(command -v bash) && git=$(command -v git) || return 1
    printf 'suites %s\nsurface %s\n%s\nbash %s %s\ngit %s %s\n' "$*" "$surface" "$machine" \
        "$bash" "$("$bash" -c 'printf %s "$BASH_VERSION"')" "$git" "$("$git" --version)"
}

die() { echo "fixture-suites: $1" >&2; exit 1; }

{ tree=$(content_tree) && inputs=$(fixture_inputs "$tree" "$@"); } || die 'cannot read the tooling a pass is recorded under'
key=$(record_name "$inputs")
# shellcheck disable=SC2046 # one path per word
untracked=$(git ls-files -o --exclude-standard -- $(tooling_surface "$tree")) || die 'cannot list the untracked files'
record="$(records_dir)/fixture/$key"

if [ -z "$untracked" ] && [ -f "$record" ]; then
    pass "fixture suites: reused the pass of $(awk '/^date / { print $2 }' "$record") recorded for this tooling"
    exit 0
fi
bash Tools/tests/git-isolation.sh "$@" || exit 1
if [ -n "$untracked" ]; then
    detail "fixture suites: not recorded, as untracked files are under the tooling: $(printf '%s\n' "$untracked" | head -5 | paste -sd ' ' -)"
elif ! { tree=$(content_tree) && after=$(fixture_inputs "$tree" "$@") && [ "$(record_name "$after")" = "$key" ]; }; then
    detail 'fixture suites: not recorded, as the tooling changed during the run'
else
    write_record fixture "$key" "$inputs" || echo "fixture-suites: cannot write the record of this pass under $(records_dir)" >&2
fi
