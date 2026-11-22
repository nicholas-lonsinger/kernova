#!/usr/bin/env bash
# Records passing lint, test and Linux test runs and posts the
# `Commit Attestation` commit status on HEAD.
#
#     Tools/attest.sh record <lint|test|test-linux>
#         What `make <kind>` runs. Runs the kind's script — Tools/lint.sh,
#         Tools/test.sh under the checkout's build lock, or Tools/test-linux.sh
#         over the content tree — and exits with its status. On exit 0 with
#         the kind's fingerprint unchanged across the run, records the
#         fingerprint under that kind. A lint run with untracked files present
#         is not recorded: lint lists what it checks from git, while a check
#         such as a link's target reads the disk, so an untracked file is read
#         without being checked.
#     Tools/attest.sh
#         Attests a clean, pushed HEAD: posts success once each kind has a
#         record of its fingerprint, recording a run of each kind it lacks,
#         and posts failure when one of those runs fails. When the Linux tests
#         lack a record and cannot run on this Mac, it names what is missing
#         and posts nothing: it brings up container and the tests' image
#         before any run, and a Tools/test-linux.sh exit of 3 is the same.
#     Tools/attest.sh post <success|failure> <description> [<target-url>]
#         Posts the status on HEAD.
#
# A fingerprint covers what a run's outcome depends on. For lint and test:
# the content tree (what `git add -A` would stage), the Xcode and macOS
# builds, and the gitignored Config/Local.xcconfig, which sets signing and
# entitlements. For test-linux: the tree of the content tree's paths
# Tools/lib/linux-tests.sh names, the only files the run reads, and the
# container release that runs it. Records are kept in the store
# Tools/lib/attest-records.sh describes. Statuses on this public repo are
# world-readable, so a description names no host or user.

set -uo pipefail

# The "Require Attestation" ruleset requires this context by name: renaming it means
# editing the ruleset.
CONTEXT='Commit Attestation'

usage() {
    echo 'usage: Tools/attest.sh [record <lint|test|test-linux> | post <success|failure> <description> [<target-url>]]' >&2
    exit 2
}

die() { echo "attest: $1" >&2; exit 1; }

# shellcheck source=lib/attest-records.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/attest-records.sh"
# shellcheck source=lib/linux-tests.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-tests.sh"

top() { git rev-parse --show-toplevel; }

# fingerprint_inputs <kind> <tree> — the lines the kind's fingerprint of
# <tree> hashes.
fingerprint_inputs() {
    local machine local_config linux container
    if [ "$1" = test-linux ]; then
        linux=$(linux_tests_tree "$2") || return 1
        container=$(container --version 2>/dev/null) || container=none
        printf 'linux-tests %s\ncontainer %s\n' "$linux" "$container"
        return
    fi
    machine=$(machine_lines) || return 1
    local_config="$(top)/Config/Local.xcconfig"
    if [ -e "$local_config" ]; then
        local_config=$(git hash-object "$local_config") || return 1
    else
        local_config=none
    fi
    printf 'tree %s\n%s\nlocal-xcconfig %s\n' "$2" "$machine" "$local_config"
}

# fingerprint <kind> <tree> — the name of the kind's record of <tree>.
fingerprint() {
    local inputs
    inputs=$(fingerprint_inputs "$1" "$2") && record_name "$inputs"
}

record() {
    [ $# -eq 1 ] || usage
    local kind=$1 root run
    root=$(top) || die 'not in a git checkout'
    case "$kind" in
        lint) run=("$root/Tools/lint.sh") ;;
        test) run=("$root/Tools/checkout-lock.sh" "$root/Tools/test.sh") ;;
        test-linux) run=("$root/Tools/test-linux.sh") ;;
        *) usage ;;
    esac
    local tree='' inputs='' before='' after='' status untracked
    if tree=$(content_tree) && inputs=$(fingerprint_inputs "$kind" "$tree"); then
        before=$(record_name "$inputs")
    else
        echo 'attest: cannot fingerprint the working tree; this run will not be recorded' >&2
    fi
    if [ "$kind" = test-linux ]; then
        [ -n "$tree" ] || die 'cannot read the content tree the Linux tests run over'
        run+=("$tree")
    fi
    "${run[@]}"
    status=$?
    [ "$status" -eq 0 ] && [ -n "$before" ] || return "$status"
    if ! { tree=$(content_tree) && after=$(fingerprint_inputs "$kind" "$tree") && [ "$(record_name "$after")" = "$before" ]; }; then
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
    local sha tree records description fp linux_fp base missing kind key status
    local ci_route="Where they cannot run, label the PR \`ci\`: CI then lints and runs both test suites on each push, and posts $CONTEXT."
    [ -z "$(git status --porcelain)" ] || die 'attest certifies HEAD; commit or stash first'
    sha=$(git rev-parse HEAD) || die 'no HEAD to attest'
    gh api "repos/{owner}/{repo}/commits/$sha" >/dev/null 2>&1 || die "GitHub does not have $sha; push first"
    tree=$(git rev-parse 'HEAD^{tree}') || die 'no HEAD tree to attest'
    fp=$(fingerprint lint "$tree") || die 'cannot read the Xcode or macOS build'
    base=$(linux_tests_base "$tree") || die 'HEAD has no .swift-version naming the Linux tests base image'
    records=$(records_dir)
    # Whether the Linux tests can run is settled before anything runs, so a
    # Mac that cannot run them spends no lint or test run first.
    linux_fp=$(fingerprint test-linux "$tree") || die 'cannot read the tree of the Linux tests'
    if [ ! -f "$records/test-linux/$linux_fp" ]; then
        missing=$(linux_tests_container_up) || die "the Linux tests need $missing. $ci_route"
        missing=$(linux_tests_container_image "$tree") || die "the Linux tests need $missing. $ci_route"
    fi
    description="make attest: Xcode $(xcode_build), macOS $(macos_build), Linux on ${base##*/}"
    # Cheapest to fail first.
    for kind in lint test-linux test; do
        key=$fp
        [ "$kind" = test-linux ] && key=$linux_fp
        if [ -f "$records/$kind/$key" ]; then
            echo "attest: reusing the passing make $kind of $(awk '/^date / { print $2 }' "$records/$kind/$key")"
            continue
        fi
        record "$kind"
        status=$?
        if [ "$kind" = test-linux ] && [ "$status" -eq 3 ]; then
            die "the Linux tests could not run, as said above. $ci_route"
        elif [ "$status" -ne 0 ]; then
            post failure "$description"
            exit 1
        elif [ ! -f "$records/$kind/$key" ]; then
            die "this $kind run recorded nothing; did files change during it?"
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
