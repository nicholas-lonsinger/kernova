#!/usr/bin/env bash
# Records passing lint and test runs and posts the `Commit Attestation` commit
# status on HEAD.
#
#     Tools/attest.sh record <lint|test>
#         Runs Tools/<kind>.sh, test's under the checkout's build lock, and
#         exits with its status. On exit 0 with the fingerprint unchanged
#         across the run, records the fingerprint under that kind. A lint run
#         with untracked files present is not recorded: lint lists what it
#         checks from git, while a check such as a link's target reads the
#         disk, so an untracked file is read without being checked.
#     Tools/attest.sh
#         Attests a clean, pushed HEAD: posts success once its fingerprint has
#         a record of each kind, running `make lint` and `make test` for the
#         ones it lacks, and posts failure when one of those fails.
#     Tools/attest.sh post <success|failure> <description> [<target-url>]
#         Posts the status on HEAD.
#
# The fingerprint covers what a run's outcome depends on: the content tree
# (what `git add -A` would stage), the Xcode and macOS builds, and the
# gitignored Config/Local.xcconfig, which sets signing and entitlements.
# Records are kept in the store Tools/lib/attest-records.sh describes. Statuses
# on this public repo are world-readable, so a description names no host or
# user.

set -uo pipefail

# The "Require Attestation" ruleset requires this context by name: renaming it means
# editing the ruleset.
CONTEXT='Commit Attestation'

usage() {
    echo 'usage: Tools/attest.sh [record <lint|test> | post <success|failure> <description> [<target-url>]]' >&2
    exit 2
}

die() { echo "attest: $1" >&2; exit 1; }

# shellcheck source=lib/attest-records.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/attest-records.sh"

top() { git rev-parse --show-toplevel; }

# fingerprint_inputs <tree> — the lines the fingerprint hashes.
fingerprint_inputs() {
    local machine local_config
    machine=$(machine_lines) || return 1
    local_config="$(top)/Config/Local.xcconfig"
    if [ -e "$local_config" ]; then
        local_config=$(git hash-object "$local_config") || return 1
    else
        local_config=none
    fi
    printf 'tree %s\n%s\nlocal-xcconfig %s\n' "$1" "$machine" "$local_config"
}

record() {
    [ $# -eq 1 ] || usage
    local kind=$1 root run
    root=$(top) || die 'not in a git checkout'
    case "$kind" in
        lint) run=("$root/Tools/lint.sh") ;;
        test) run=("$root/Tools/checkout-lock.sh" "$root/Tools/test.sh") ;;
        *) usage ;;
    esac
    local tree inputs='' before='' after='' status untracked
    if tree=$(content_tree) && inputs=$(fingerprint_inputs "$tree"); then
        before=$(record_name "$inputs")
    else
        echo 'attest: cannot fingerprint the working tree; this run will not be recorded' >&2
    fi
    "${run[@]}"
    status=$?
    [ "$status" -eq 0 ] && [ -n "$before" ] || return "$status"
    if ! { tree=$(content_tree) && after=$(fingerprint_inputs "$tree") && [ "$(record_name "$after")" = "$before" ]; }; then
        echo 'attest: the files changed during the run, so it is not recorded' >&2
    elif [ "$kind" = lint ] && untracked=$(cd "$root" && git ls-files -o --exclude-standard) && [ -n "$untracked" ]; then
        echo "attest: untracked files are present, so this lint run is not recorded: $(printf '%s\n' "$untracked" | head -5 | paste -sd ' ' -)" >&2
    else
        write_record "$kind" "$before" "$inputs" ||
            echo "attest: cannot write the record of this passing run under $(records_dir)" >&2
    fi
    return 0
}

post() {
    [ $# -ge 2 ] && [ $# -le 3 ] || usage
    case "$1" in success | failure) ;; *) echo "attest: a status is success or failure, not '$1'" >&2; usage ;; esac
    local sha args
    sha=$(git rev-parse HEAD) || die 'no HEAD to post on'
    args=(-f "state=$1" -f "context=$CONTEXT" -f "description=$2")
    [ $# -eq 3 ] && args+=(-f "target_url=$3")
    gh api -X POST "repos/{owner}/{repo}/statuses/$sha" "${args[@]}" >/dev/null ||
        die "posting the $CONTEXT status on $sha failed"
    echo "attest: posted $CONTEXT = $1 on $sha"
}

attest() {
    local sha inputs fp records description kind
    [ -z "$(git status --porcelain)" ] || die 'attest certifies HEAD; commit or stash first'
    sha=$(git rev-parse HEAD) || die 'no HEAD to attest'
    gh api "repos/{owner}/{repo}/commits/$sha" >/dev/null 2>&1 || die "GitHub does not have $sha; push first"
    inputs=$(fingerprint_inputs "$(git rev-parse 'HEAD^{tree}')") || die 'cannot read the Xcode or macOS build'
    fp=$(record_name "$inputs")
    records=$(records_dir)
    description="make attest: Xcode $(xcode_build), macOS $(macos_build)"
    # Lint first: it is the faster of the two to fail.
    for kind in lint test; do
        if [ -f "$records/$kind/$fp" ]; then
            echo "attest: reusing the passing make $kind of $(awk '/^date / { print $2 }' "$records/$kind/$fp")"
        elif ! "${MAKE:-make}" "$kind"; then
            post failure "$description"
            exit 1
        elif [ ! -f "$records/$kind/$fp" ]; then
            die "make $kind recorded nothing; did files change during it?"
        fi
    done
    post success "$description"
}

case "${1:-}" in
    '') attest ;;
    record) shift; record "$@" ;;
    post) shift; post "$@" ;;
    *) usage ;;
esac
