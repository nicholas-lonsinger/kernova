#!/usr/bin/env bash
# Records passing lint and test runs and posts the `Commit Attestation` commit
# status on HEAD.
#
#     Tools/attest.sh record <lint|test> -- <command> [<arg>...]
#         Runs the command untouched and exits with its status. On exit 0 with
#         the fingerprint unchanged across the run, records the fingerprint
#         under that kind.
#     Tools/attest.sh
#         Attests a clean, pushed HEAD: posts success once its fingerprint has
#         a record of each kind, running `make lint` and `make test` for the
#         ones it lacks, and posts failure when one of those fails.
#     Tools/attest.sh post <success|failure> <description> [<target-url>]
#         Posts the status on HEAD.
#
# The fingerprint covers what a run's outcome depends on: the content
# tree (what `git add -A` would stage), the Xcode and macOS builds, and the
# gitignored Config/Local.xcconfig, which sets signing and entitlements.
# Records live in the common git dir, so every worktree shares them. Statuses
# on this public repo are world-readable, so a description names no host or
# user.

set -uo pipefail

# The "Require Attestation" ruleset requires this context by name: renaming it means
# editing the ruleset.
CONTEXT='Commit Attestation'

usage() {
    echo 'usage: Tools/attest.sh [record <lint|test> -- <command> [<arg>...] | post <success|failure> <description> [<target-url>]]' >&2
    exit 2
}

die() { echo "attest: $1" >&2; exit 1; }

top() { git rev-parse --show-toplevel; }
records_dir() { printf '%s/kernova-attest' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
xcode_build() { xcodebuild -version 2>/dev/null | awk '/^Build version/ { print $3 }'; }
macos_build() { sw_vers -buildVersion; }

# content_tree — the tree `git add -A` would stage, built in a copy of the
# index so its stat data is reused and the real index stays untouched.
content_tree() {
    local index scratch tree
    index=$(git rev-parse --path-format=absolute --git-path index) || return 1
    scratch=$(mktemp -d) || return 1
    if [ -e "$index" ]; then cp "$index" "$scratch/index" || { rm -rf "$scratch"; return 1; }; fi
    tree=$(cd "$(top)" && GIT_INDEX_FILE="$scratch/index" git add -A && GIT_INDEX_FILE="$scratch/index" git write-tree)
    local status=$?
    rm -rf "$scratch"
    [ "$status" -eq 0 ] && printf '%s\n' "$tree"
}

# fingerprint_inputs <tree> — the lines the fingerprint hashes.
fingerprint_inputs() {
    local xcode macos local_config
    xcode=$(xcode_build) && [ -n "$xcode" ] || return 1
    macos=$(macos_build) && [ -n "$macos" ] || return 1
    local_config="$(top)/Config/Local.xcconfig"
    if [ -e "$local_config" ]; then
        local_config=$(git hash-object "$local_config") || return 1
    else
        local_config=none
    fi
    printf 'tree %s\nxcode %s\nmacos %s\nlocal-xcconfig %s\n' "$1" "$xcode" "$macos" "$local_config"
}

fingerprint() { git hash-object --stdin <<<"$1"; }

# write_record <kind> <fingerprint> <inputs> — the record, plus pruning records
# of every kind older than 30 days.
write_record() {
    local root dir
    root=$(records_dir) || return 1
    dir="$root/$1"
    mkdir -p "$dir" || return 1
    if ! { printf '%s\ndate %s\n' "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/$2.tmp" &&
        mv "$dir/$2.tmp" "$dir/$2"; }; then
        rm -f "$dir/$2.tmp"
        return 1
    fi
    find "$root" -type f -mtime +30 -delete
}

record() {
    case "${1:-}" in lint | test) ;; *) usage ;; esac
    [ "${2:-}" = -- ] && [ $# -ge 3 ] || usage
    local kind=$1
    shift 2
    local tree inputs='' before='' after='' status
    if tree=$(content_tree) && inputs=$(fingerprint_inputs "$tree"); then
        before=$(fingerprint "$inputs")
    else
        echo 'attest: cannot fingerprint the working tree; this run will not be recorded' >&2
    fi
    "$@"
    status=$?
    [ "$status" -eq 0 ] && [ -n "$before" ] || return "$status"
    if tree=$(content_tree) && after=$(fingerprint_inputs "$tree") && [ "$(fingerprint "$after")" = "$before" ]; then
        write_record "$kind" "$before" "$inputs" ||
            echo "attest: cannot write the record of this passing run under $(records_dir)" >&2
    else
        echo 'attest: the files changed during the run, so it is not recorded' >&2
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
    fp=$(fingerprint "$inputs")
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
