#!/usr/bin/env bash
# Runs each fixture suite given as an argument from its stage, the way
# `pre-push` runs it from a linked worktree — working directory in the
# worktree, GIT_DIR naming its gitdir — but against a decoy repository built
# here, and fails a fixture that changes the decoy's config. `make lint` runs
# the fixture suites through this, so no fixture reaches the repository that
# invoked it.
#
#     Tools/fixture-suites.sh [--reuse] <suite, relative to the repo root>...
#
# A suite's stage is a git checkout, outside this repository, of the content
# tree (what `git add -A` would stage) cut down to the suite, the paths its
# header declares it reads (lint_fixture_reads in Tools/lib/lint-inputs.sh),
# this runner and the paths its own header declares, and the root's dotfiles:
# tools find those by searching upward, so a stage without one would change a
# tool's behavior instead of failing it. The suite runs from its stage with no
# exported variable naming this checkout, so a file it reads outside its
# stage is absent there and the suite fails. A stage holding
# Tools/install-dead-code-tool.sh is given the release dead-code-sources that
# installer builds from the stage's files (fixture_dead_code_sources in
# Tools/lib/dead-code-tool.sh).
#
# A passing suite is recorded (Tools/lib/attest-records.sh) under its stage's
# tree and the Xcode and macOS builds; with --reuse, a suite with such a
# record is not run.
#
# fixture reads: Tools/lib/git-isolation.sh Tools/lib/attest-records.sh Tools/lib/lint-inputs.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER=Tools/fixture-suites.sh

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
die() { echo "fixture-suites: $1, so no suite ran" >&2; exit 1; }

reuse=0
if [ "${1:-}" = --reuse ]; then
    reuse=1
    shift
fi

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
# shellcheck source=lib/attest-records.sh
. "$ROOT/Tools/lib/attest-records.sh"
# shellcheck source=lib/lint-inputs.sh
. "$ROOT/Tools/lib/lint-inputs.sh"

# ---- stages, in the caller's environment ----------------------------------------
#
# The tool cache dead-code-sources comes from is under the caller's HOME, and
# the content is this checkout's, whatever GIT_DIR the caller exported.

# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
cd "$ROOT" || exit 1
tree=$(content_tree) || die "cannot read this checkout's content"
machine=$(machine_lines) || die 'cannot read the Xcode or macOS build'
records=$(records_dir) || die 'cannot find the record store'
runner_reads=$(lint_fixture_reads "$RUNNER") || exit 1
dotfiles=$(git ls-tree "$tree" | awk -F '\t' '$1 ~ / blob / && $2 ~ /^\./ { print $2 }') ||
    die "cannot list this checkout's root"

# stage_git <git argument>... — git with no configuration but the repository's,
# so a checkout writes the bytes the tree holds.
stage_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# stage_tree <path>... — the content tree cut down to these paths, each a file
# or directory in it.
stage_tree() {
    local listing missing
    listing=$(git ls-tree -r --full-tree "$tree" -- "$@") || return 1
    missing=$(printf '%s\n' "$listing" | WANTED="$(printf '%s\n' "$@")" awk -F '\t' '
        BEGIN { n = split(ENVIRON["WANTED"], want, "\n") }
        { for (i = 1; i <= n; i++) if ($2 == want[i] || index($2, want[i] "/") == 1) seen[i] = 1 }
        END { for (i = 1; i <= n; i++) if (!seen[i]) print want[i] }') || return 1
    if [ -n "$missing" ]; then
        echo "not in the checkout: $(printf '%s\n' "$missing" | paste -sd ' ' -)" >&2
        return 1
    fi
    rm -f "$tmp/stage.index"
    printf '%s\n' "$listing" | GIT_INDEX_FILE="$tmp/stage.index" git update-index --index-info &&
        GIT_INDEX_FILE="$tmp/stage.index" git write-tree
}

# make_stage <tree> <dir> — a checkout of <tree> at <dir>, reading its objects
# from this repository's.
make_stage() {
    stage_git init -q "$2" &&
        git rev-parse --path-format=absolute --git-path objects >"$2/.git/objects/info/alternates" &&
        stage_git -C "$2" read-tree "$1" &&
        stage_git -C "$2" checkout-index -a
}

planned=()
reused=0
for fixture in "$@"; do
    name=$(printf '%s' "$fixture" | tr '/.' '__')
    if ! reads=$(lint_fixture_reads "$fixture"); then
        fail "$fixture: its header's reads do not parse"
        continue
    fi
    # shellcheck disable=SC2086 # one path per word
    if ! staged=$(stage_tree "$fixture" $reads "$RUNNER" $runner_reads $dotfiles 2>"$tmp/err"); then
        fail "$fixture: its stage cannot be built: $(cat "$tmp/err")"
        continue
    fi
    lines=$(printf 'suite %s\ntree %s\n%s' "$fixture" "$staged" "$machine")
    key=$(record_name "$lines")
    if [ "$reuse" -eq 1 ] && [ -f "$records/fixture/$key" ]; then
        reused=$((reused + 1))
        continue
    fi
    stage="$tmp/stages/$name"
    if ! make_stage "$staged" "$stage" 2>"$tmp/err"; then
        fail "$fixture: its stage cannot be checked out: $(cat "$tmp/err")"
        continue
    fi
    dead_code_sources=''
    if [ -f "$stage/Tools/install-dead-code-tool.sh" ] &&
        ! dead_code_sources=$("$stage/Tools/install-dead-code-tool.sh" dead-code-sources); then
        fail "$fixture: dead-code-sources does not install from its stage"
        continue
    fi
    printf '%s\n' "$lines" >"$tmp/$name.lines"
    printf '%s\n' "$dead_code_sources" >"$tmp/$name.dead-code-sources"
    planned+=("$fixture")
done
[ "$reused" -eq 0 ] ||
    printf '  %s✓%s fixture suites: reused the recorded pass of %d whose stage is unchanged\n' "$c_green" "$c_reset" "$reused"

# ---- runs, isolated -------------------------------------------------------------

isolate_git "$tmp"

# new_decoy <name> — a primary checkout under $tmp/<name> with a linked
# worktree at $tmp/<name>-wt; prints the worktree's gitdir.
new_decoy() {
    git init -q -b main "$tmp/$1" && git -C "$tmp/$1" commit -q --allow-empty -m init &&
        git -C "$tmp/$1" worktree add -q -b wt "$tmp/$1-wt" &&
        git -C "$tmp/$1-wt" rev-parse --absolute-git-dir
}

bare() { git config --file "$tmp/$1/.git/config" --get core.bare; }

# unexport_checkout — leaves no exported variable naming this checkout and no
# PATH entry inside it.
unexport_checkout() {
    local physical var entry path=''
    physical=$(cd "$ROOT" && pwd -P)
    for var in $(compgen -e); do
        [ "$var" != PATH ] || continue
        case "${!var}" in *"$ROOT"* | *"$physical"*) unset "$var" ;; esac
    done
    while IFS= read -r -d : entry; do
        case "$entry" in "$ROOT" | "$ROOT"/* | "$physical" | "$physical"/*) ;; *) path+="$entry:" ;; esac
    done <<<"$PATH:"
    export PATH="${path%:}"
}

# The decoy has to reproduce the failure, or a fixture that leaks would pass:
# an unisolated `git init` under its environment marks it bare.
gitdir=$(new_decoy canary) || { echo 'fixture-suites: cannot build the decoy repository' >&2; exit 1; }
(cd "$tmp/canary-wt" && GIT_DIR="$gitdir" git init -q "$tmp/canary-init")
if [ "$(bare canary)" != true ]; then
    fail "canary: an unisolated git init under GIT_DIR=$gitdir left core.bare '$(bare canary)'; the decoy no longer reproduces a leak"
fi

for fixture in ${planned[@]+"${planned[@]}"}; do
    name=$(printf '%s' "$fixture" | tr '/.' '__')
    stage="$tmp/stages/$name"
    gitdir=$(new_decoy "$name") || { fail "$fixture: cannot build its decoy repository"; continue; }
    before=$(cat "$tmp/$name/.git/config")
    dead_code_sources=$(cat "$tmp/$name.dead-code-sources")
    if ! (
        cd "$tmp/$name-wt" || exit 1
        unexport_checkout
        if [ -n "$dead_code_sources" ]; then
            export KERNOVA_FIXTURE_DEAD_CODE_SOURCES="$dead_code_sources"
        else
            unset KERNOVA_FIXTURE_DEAD_CODE_SOURCES
        fi
        GIT_DIR="$gitdir" bash "$stage/$fixture"
    ); then
        fail "$fixture: failed, run from a stage holding only the paths its header declares it reads"
        continue
    fi
    if [ "$(bare "$name")" != false ]; then
        fail "$fixture: set core.bare '$(bare "$name")' in the repository whose GIT_DIR it inherited"
    elif [ "$(cat "$tmp/$name/.git/config")" != "$before" ]; then
        fail "$fixture: changed the config of the repository whose GIT_DIR it inherited"
    else
        lines=$(cat "$tmp/$name.lines")
        (cd "$ROOT" && write_record fixture "$(record_name "$lines")" "$lines") ||
            echo "fixture-suites: cannot write the record of $fixture's pass under $records" >&2
    fi
done

if [ "$FAIL" -gt 0 ]; then
    printf 'fixture-suites: %d failed\n' "$FAIL" >&2
    exit 1
fi
