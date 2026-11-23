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
#         is not recorded: the fingerprint covers them, but shellcheck checks
#         only the scripts git tracks, so an untracked script would be
#         recorded without being checked.
#     Tools/attest.sh
#         Attests a clean, pushed HEAD: posts success once each kind has a
#         record of its fingerprint, recording a run of each kind it lacks,
#         and posts failure when one of those runs fails. When the Linux tests
#         lack a record and cannot run on this Mac, it names what is missing
#         and posts nothing: it brings up container and the tests' image
#         before any run, and a Tools/test-linux.sh exit of 3 is the same.
#         Interrupted, it posts nothing and stops.
#     Tools/attest.sh post <success|failure> <description> [<target-url>]
#         Posts the status on HEAD.
#     Tools/attest.sh attested-parent
#         Prints HEAD's parent when the parent carries a passing status and
#         HEAD has its build inputs, so the build and tests that status
#         attests stand for HEAD's; prints nothing otherwise. CI runs it to
#         decide whether to build and test.
#
# A fingerprint covers what a run's outcome depends on. For lint: the content
# tree (what `git add -A` would stage); for test: that tree's build inputs.
# Both add the Xcode and macOS builds and the gitignored
# Config/Local.xcconfig, which sets signing and entitlements. For test-linux:
# the tree of the content tree's paths Tools/lib/linux-tests.sh names, the
# only files the run reads, and the container release that runs it. Records
# are kept in the store Tools/lib/attest-records.sh describes. Statuses on
# this public repo are world-readable, so a description names no host or user.

set -uo pipefail

# The "Require Attestation" ruleset requires this context by name: renaming it means
# editing the ruleset.
CONTEXT='Commit Attestation'

usage() {
    echo 'usage: Tools/attest.sh [record <lint|test|test-linux> | post <success|failure> <description> [<target-url>] | attested-parent]' >&2
    exit 2
}

die() { echo "attest: $1" >&2; exit 1; }

# shellcheck source=lib/attest-records.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/attest-records.sh"
# shellcheck source=lib/linux-tests.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-tests.sh"

top() { git rev-parse --show-toplevel; }

# build_inputs <tree-ish> — a hash of <tree-ish>'s build inputs: every path
# but those no build or test reads — Markdown, docs/, the agents' own
# configuration and the issue templates. A path stays an input unless it
# plainly cannot change a built product or a test's outcome.
build_inputs() {
    git ls-tree -r --full-tree "$1" |
        awk -F '\t' '$2 !~ /\.md$|^(docs|\.agents|\.claude|\.github\/ISSUE_TEMPLATE)\//' |
        git hash-object --stdin
}

# fingerprint_inputs <kind> <tree> — the lines the kind's fingerprint of
# <tree> hashes.
fingerprint_inputs() {
    local content machine local_config linux container
    case "$1" in
        test-linux)
            linux=$(linux_tests_tree "$2") || return 1
            container=$(container --version 2>/dev/null) || container=none
            printf 'linux-tests %s\ncontainer %s\n' "$linux" "$container"
            return
            ;;
        test) content="build-inputs $(build_inputs "$2")" || return 1 ;;
        *) content="tree $2" ;;
    esac
    machine=$(machine_lines) || return 1
    local_config="$(top)/Config/Local.xcconfig"
    if [ -e "$local_config" ]; then
        local_config=$(git hash-object "$local_config") || return 1
    else
        local_config=none
    fi
    printf '%s\n%s\nlocal-xcconfig %s\n' "$content" "$machine" "$local_config"
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
    local sha tree records description linux_fp base missing kind key status
    local ci_route="Where they cannot run, label the PR \`ci\`: CI then posts $CONTEXT on each push."
    # A run that was interrupted posts nothing: xcodebuild exits 75 on SIGINT
    # rather than dying of it, and container's first process ignores it, so
    # neither run's status says it was interrupted. bash runs this once the
    # run in the foreground returns.
    trap 'die "interrupted; nothing posted"' INT TERM HUP
    [ -z "$(git status --porcelain)" ] || die 'attest certifies HEAD; commit or stash first'
    sha=$(git rev-parse HEAD) || die 'no HEAD to attest'
    gh api "repos/{owner}/{repo}/commits/$sha" >/dev/null 2>&1 || die "GitHub does not have $sha; push first"
    tree=$(git rev-parse 'HEAD^{tree}') || die 'no HEAD tree to attest'
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
        key=$(fingerprint "$kind" "$tree") || die "cannot fingerprint the $kind run"
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

attested_parent() {
    [ $# -eq 0 ] || usage
    local parent head inputs state
    parent=$(git rev-parse -q --verify 'HEAD^1^{commit}') || return 0
    if ! head=$(build_inputs HEAD) || ! inputs=$(build_inputs "$parent"); then
        die 'cannot read the build inputs of HEAD and its parent'
    fi
    [ "$head" = "$inputs" ] || return 0
    state=$(gh api "repos/{owner}/{repo}/commits/$parent/status" --jq ".statuses[] | select(.context == \"$CONTEXT\") | .state") ||
        die "reading the statuses of $parent failed"
    [ "$state" != success ] || printf '%s\n' "$parent"
}

case "${1:-}" in
    '') attest ;;
    record) shift; record "$@" ;;
    post) shift; post "$@" ;;
    attested-parent) shift; attested_parent "$@" ;;
    *) usage ;;
esac
