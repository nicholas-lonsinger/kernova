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
# A suite's stage is a git checkout, outside this repository, of the whole
# content tree (what `git add -A` would stage), whose index holds only what
# the suite's outcome may depend on: the suite, the paths its header declares
# it reads (fixture_reads in Tools/lib/fixture-reads.sh), this runner and the
# paths its own header declares, and the root's dotfiles, which tools find by
# searching upward. The suite runs with no exported variable or PATH entry
# naming this checkout, so it reaches the checkout only through its stage.
#
# Every file in the stage starts the run with an access time in 2000, and
# reading one — running or sourcing it, or reading it as data — sets it to the
# time of the read, so a suite that read a file its index does not cover
# fails, whatever its status. Presence is not traced: a name found by listing
# a directory or testing a path, without reading the file, sets no file's
# access time, and a directory's cannot tell a listing from running a file in
# it, which sets it too.
#
# A stage whose index holds Tools/install-dead-code-tool.sh is given the
# release dead-code-sources that installer resolves from the stage, within
# the suite's run (fixture_dead_code_sources in Tools/lib/dead-code-tool.sh).
#
# A passing suite is recorded (Tools/lib/attest-records.sh) under its index's
# tree, the Xcode and macOS builds, and the bash and git it runs; with
# --reuse, a suite with such a record is not run.
#
# fixture reads: Tools/lib/git-isolation.sh Tools/lib/attest-records.sh Tools/lib/fixture-reads.sh

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
# shellcheck source=lib/fixture-reads.sh
. "$ROOT/Tools/lib/fixture-reads.sh"

# ---- keys, in the caller's environment -----------------------------------------
#
# The content is this checkout's, whatever GIT_DIR the caller exported, and the
# tool cache dead-code-sources comes from is under the caller's HOME.

# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
cd "$ROOT" || exit 1
physical=$(pwd -P)
caller_home=$HOME

# outside_checkout <PATH> — the PATH without its entries inside this checkout.
outside_checkout() {
    local entry kept=''
    while IFS= read -r -d : entry; do
        case "$entry" in "$ROOT" | "$ROOT"/* | "$physical" | "$physical"/*) ;; *) kept+="$entry:" ;; esac
    done <<<"$1:"
    printf '%s\n' "${kept%:}"
}
suite_path=$(outside_checkout "$PATH")

# tool_lines — the record lines naming the bash and git a suite runs, which
# PATH chooses.
tool_lines() {
    local bash git
    bash=$(command -v bash) && git=$(command -v git) || return 1
    printf 'bash %s %s\ngit %s %s\n' "$bash" "$("$bash" -c 'printf %s "$BASH_VERSION"')" "$git" "$("$git" --version)"
}

tree=$(content_tree) || die "cannot read this checkout's content"
machine=$(machine_lines) || die 'cannot read the Xcode or macOS build'
tools=$(PATH="$suite_path" tool_lines) || die 'cannot find the bash and git a suite runs'
records=$(records_dir) || die 'cannot find the record store'
runner_reads=$(fixture_reads "$RUNNER") || exit 1
git ls-tree -r --name-only --full-tree "$tree" >"$tmp/content" || die "cannot list this checkout's content"
dotfiles=$(git ls-tree "$tree" | awk -F '\t' '$1 ~ / blob / && $2 ~ /^\./ { print $2 }') ||
    die "cannot list this checkout's root"

# index_tree <path>... — the content tree cut down to these paths, each a file
# or directory in it.
index_tree() {
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
    rm -f "$tmp/index"
    printf '%s\n' "$listing" | GIT_INDEX_FILE="$tmp/index" git update-index --index-info &&
        GIT_INDEX_FILE="$tmp/index" git write-tree
}

planned=()
reused=0
for fixture in "$@"; do
    name=$(printf '%s' "$fixture" | tr '/.' '__')
    if ! reads=$(fixture_reads "$fixture"); then
        fail "$fixture: its header's reads do not parse"
        continue
    fi
    # shellcheck disable=SC2086 # one path per word
    covered=$(printf '%s\n' "$fixture" $reads "$RUNNER" $runner_reads $dotfiles)
    # shellcheck disable=SC2086 # one path per word
    if ! indexed=$(index_tree $covered 2>"$tmp/err"); then
        fail "$fixture: its stage cannot be built: $(cat "$tmp/err")"
        continue
    fi
    lines=$(printf 'suite %s\ntree %s\n%s\n%s' "$fixture" "$indexed" "$machine" "$tools")
    key=$(record_name "$lines")
    if [ "$reuse" -eq 1 ] && [ -f "$records/fixture/$key" ]; then
        reused=$((reused + 1))
        continue
    fi
    printf '%s\n' "$lines" >"$tmp/$name.lines"
    printf '%s\n' "$indexed" >"$tmp/$name.tree"
    printf '%s\n' "$covered" >"$tmp/$name.covered"
    planned+=("$fixture")
done
[ "$reused" -eq 0 ] ||
    printf '  %s✓%s fixture suites: reused the recorded pass of %d whose stage is unchanged\n' "$c_green" "$c_reset" "$reused"

# ---- runs, isolated -------------------------------------------------------------

objects=$(git rev-parse --path-format=absolute --git-path objects) || die 'cannot find the object store'
isolate_git "$tmp"

# new_decoy <name> — a primary checkout under $tmp/<name> with a linked
# worktree at $tmp/<name>-wt; prints the worktree's gitdir.
new_decoy() {
    git init -q -b main "$tmp/$1" && git -C "$tmp/$1" commit -q --allow-empty -m init &&
        git -C "$tmp/$1" worktree add -q -b wt "$tmp/$1-wt" &&
        git -C "$tmp/$1-wt" rev-parse --absolute-git-dir
}

bare() { git config --file "$tmp/$1/.git/config" --get core.bare; }

# make_stage <index tree> <dir> — the content tree checked out at <dir>, its
# index holding <index tree>, every access time in 2000.
make_stage() {
    git init -q "$2" && printf '%s\n' "$objects" >"$2/.git/objects/info/alternates" &&
        git -C "$2" read-tree "$tree" && git -C "$2" checkout-index -a && git -C "$2" read-tree "$1" &&
        find "$2" -path "$2/.git" -prune -o ! -type d -print0 | xargs -0 touch -a -h -t 200001010000
}

# covers <covered> <path> — whether a path in the file <covered> holds <path>.
covers() {
    awk -v path="$2" '$0 == path || index(path, $0 "/") == 1 { found = 1; exit } END { exit !found }' "$1"
}

# uncovered_reads <dir> <covered> — the content-tree files read in the stage at
# <dir> that no path in the file <covered> holds.
uncovered_reads() {
    (cd "$1" && find . -path ./.git -prune -o ! -type d -newerat 2000-01-02 -print) |
        awk -v covered="$2" -v content="$tmp/content" '
            BEGIN {
                while ((getline path < covered) > 0) cover[++n] = path
                while ((getline path < content) > 0) file[path] = 1
            }
            {
                path = substr($0, 3)
                if (!(path in file)) next
                for (i = 1; i <= n; i++) if (path == cover[i] || index(path, cover[i] "/") == 1) next
                print path
            }'
}

# The decoy has to reproduce the failure, or a fixture that leaks would pass:
# an unisolated `git init` under its environment marks it bare.
gitdir=$(new_decoy canary) || { echo 'fixture-suites: cannot build the decoy repository' >&2; exit 1; }
(cd "$tmp/canary-wt" && GIT_DIR="$gitdir" git init -q "$tmp/canary-init")
if [ "$(bare canary)" != true ]; then
    fail "canary: an unisolated git init under GIT_DIR=$gitdir left core.bare '$(bare canary)'; the decoy no longer reproduces a leak"
fi
# The trace has to see a read, or a suite reading what it never declared would pass.
printf 'canary\n' >"$tmp/read-canary" && touch -a -t 200001010000 "$tmp/read-canary" && cat "$tmp/read-canary" >/dev/null
[ -n "$(find "$tmp/read-canary" -newerat 2000-01-02)" ] ||
    die "reading a file under $tmp leaves its access time as it was, so a suite's reads cannot be traced"

for fixture in ${planned[@]+"${planned[@]}"}; do
    name=$(printf '%s' "$fixture" | tr '/.' '__')
    stage="$tmp/stages/$name"
    if ! make_stage "$(cat "$tmp/$name.tree")" "$stage"; then
        fail "$fixture: its stage cannot be checked out"
        continue
    fi
    gitdir=$(new_decoy "$name") || { fail "$fixture: cannot build its decoy repository"; continue; }
    before=$(cat "$tmp/$name/.git/config")
    dead_code_sources=''
    if covers "$tmp/$name.covered" Tools/install-dead-code-tool.sh &&
        ! dead_code_sources=$(cd "$stage" &&
            HOME="$caller_home" PATH="$suite_path" Tools/install-dead-code-tool.sh dead-code-sources); then
        fail "$fixture: dead-code-sources does not install from its stage"
        rm -rf "$stage"
        continue
    fi
    (
        cd "$tmp/$name-wt" || exit 1
        for var in $(compgen -e); do
            case "${!var}" in *"$ROOT"* | *"$physical"*) [ "$var" = PATH ] || unset "$var" ;; esac
        done
        export PATH="$suite_path"
        if [ -n "$dead_code_sources" ]; then
            export KERNOVA_FIXTURE_DEAD_CODE_SOURCES="$dead_code_sources"
        else
            unset KERNOVA_FIXTURE_DEAD_CODE_SOURCES
        fi
        GIT_DIR="$gitdir" bash "$stage/$fixture"
    )
    status=$?
    uncovered=$(uncovered_reads "$stage" "$tmp/$name.covered" | paste -sd ' ' -) || uncovered='(its stage could not be read)'
    rm -rf "$stage"
    if [ -n "$uncovered" ]; then
        fail "$fixture: read what its header does not declare: $uncovered"
    elif [ "$status" -ne 0 ]; then
        fail "$fixture: failed"
    elif [ "$(bare "$name")" != false ]; then
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
