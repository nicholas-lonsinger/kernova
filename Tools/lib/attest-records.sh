# The store of passing runs: Tools/attest.sh's lint, test and Linux test runs
# and Tools/fixture-suites.sh's suites. Sourced, never run; run from inside the
# checkout.
#
# A record is a file under <kind>/ named by the hash of the lines it holds,
# which name everything the run's outcome depends on. The store is in the
# common git dir, so every worktree shares it.

# shellcheck shell=bash

records_dir() { printf '%s/kernova-attest' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
xcode_build() { xcodebuild -version 2>/dev/null | awk '/^Build version/ { print $3 }'; }
macos_build() { sw_vers -buildVersion; }

# machine_lines — the record lines naming the Xcode and macOS builds.
machine_lines() {
    local xcode macos
    xcode=$(xcode_build) && [ -n "$xcode" ] || return 1
    macos=$(macos_build) && [ -n "$macos" ] || return 1
    printf 'xcode %s\nmacos %s\n' "$xcode" "$macos"
}

# content_tree — the tree `git add -A` would stage, built in a copy of the
# index so its stat data is reused and the real index stays untouched.
content_tree() {
    local index scratch tree
    index=$(git rev-parse --path-format=absolute --git-path index) || return 1
    scratch=$(mktemp -d) || return 1
    if [ -e "$index" ]; then cp "$index" "$scratch/index" || { rm -rf "$scratch"; return 1; }; fi
    tree=$(cd "$(git rev-parse --show-toplevel)" && GIT_INDEX_FILE="$scratch/index" git add -A &&
        GIT_INDEX_FILE="$scratch/index" git write-tree)
    local status=$?
    rm -rf "$scratch"
    [ "$status" -eq 0 ] && printf '%s\n' "$tree"
}

# record_name <lines> — the name of the record holding <lines>.
record_name() { git hash-object --stdin <<<"$1"; }

# write_record <kind> <name> <lines> — the record, plus pruning records of
# every kind older than 30 days.
write_record() {
    local root dir staged
    root=$(records_dir) || return 1
    dir="$root/$1"
    mkdir -p "$dir" || return 1
    staged=$(mktemp "$dir/.$2.XXXXXX") || return 1
    if ! { printf '%s\ndate %s\n' "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$staged" && mv "$staged" "$dir/$2"; }; then
        rm -f "$staged"
        return 1
    fi
    find "$root" -type f -mtime +30 -delete
}
