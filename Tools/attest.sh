#!/usr/bin/env bash
# Records passing test runs and posts the `tests` commit status on HEAD.
#
#     Tools/attest.sh record -- <command> [<arg>...]
#         Runs the command untouched and exits with its status. On exit 0 with
#         the fingerprint unchanged across the run, records the fingerprint.
#     Tools/attest.sh
#         Attests a clean, pushed HEAD: posts success when its fingerprint has
#         a record, otherwise runs `make test` and posts its outcome.
#     Tools/attest.sh post <success|failure> <description> [<target-url>]
#         Posts the status on HEAD.
#
# The fingerprint covers what a test run's outcome depends on: the content
# tree (what `git add -A` would stage), the Xcode and macOS builds, and the
# gitignored Config/Local.xcconfig, which sets signing and entitlements.
# Records live in the common git dir, so every worktree shares them. Statuses
# on this public repo are world-readable, so a description names no host or
# user.

set -uo pipefail

# The "Require Tests" ruleset requires this context by name: renaming it means
# editing the ruleset.
CONTEXT=tests

usage() {
    echo 'usage: Tools/attest.sh [record -- <command> [<arg>...] | post <success|failure> <description> [<target-url>]]' >&2
    exit 2
}

die() { echo "attest: $1" >&2; exit 1; }

top() { git rev-parse --show-toplevel; }
records_dir() { printf '%s/kernova-tests' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
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

# write_record <fingerprint> <inputs> — the record, plus pruning records older
# than 30 days.
write_record() {
    local dir
    dir=$(records_dir) || return 1
    mkdir -p "$dir" || return 1
    if ! { printf '%s\ndate %s\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/$1.tmp" &&
        mv "$dir/$1.tmp" "$dir/$1"; }; then
        rm -f "$dir/$1.tmp"
        return 1
    fi
    find "$dir" -type f -mtime +30 -delete
}

record() {
    [ "${1:-}" = -- ] && [ $# -ge 2 ] || usage
    shift
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
        write_record "$before" "$inputs" ||
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
    local sha inputs fp records description
    [ -z "$(git status --porcelain)" ] || die 'attest certifies HEAD; commit or stash first'
    sha=$(git rev-parse HEAD) || die 'no HEAD to attest'
    gh api "repos/{owner}/{repo}/commits/$sha" >/dev/null 2>&1 || die "GitHub does not have $sha; push first"
    inputs=$(fingerprint_inputs "$(git rev-parse 'HEAD^{tree}')") || die 'cannot read the Xcode or macOS build'
    fp=$(fingerprint "$inputs")
    records=$(records_dir)
    description="make attest: Xcode $(xcode_build), macOS $(macos_build)"
    if [ -f "$records/$fp" ]; then
        echo "attest: reusing the passing make test of $(awk '/^date / { print $2 }' "$records/$fp")"
    elif ! "${MAKE:-make}" test; then
        post failure "$description"
        exit 1
    elif [ ! -f "$records/$fp" ]; then
        die 'the run recorded nothing; did files change during it?'
    fi
    post success "$description"
}

case "${1:-}" in
    '') attest ;;
    record) shift; record "$@" ;;
    post) shift; post "$@" ;;
    *) usage ;;
esac
