# Build arenas and the Launch Services records of the bundles built into them,
# for Tools/build-arenas.sh and Tools/ghosts.sh. Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/output.sh"
#     . "$REPO_ROOT/Tools/lib/worktrees.sh"
#     . "$REPO_ROOT/Tools/lib/build-arenas.sh"
#
# The two before it define functions it calls.

# shellcheck shell=bash

build_arenas_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# lsregister is called by name; macOS keeps it off the default PATH.
PATH="$PATH:/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support"

# kernova_registered_paths — every path Launch Services holds a record for
# under the app.kernova* identifiers or the legacy com.kernova.app one, one per
# line.
#
# lsregister's dump lists `path:` a few lines before the `identifier:` line for
# the same entry, with entries separated by a full-width dash rule — the most
# recently seen path is reset at each rule so an identifier never gets paired
# with a path from a different entry.
kernova_registered_paths() {
    lsregister -dump 2>/dev/null | awk '
        /^-+$/ { path = "" }
        /^path:/ {
            line = $0
            sub(/^path:[ \t]*/, "", line)
            sub(/ \(0x[0-9a-fA-F]+\)[ \t]*$/, "", line)
            path = line
        }
        /^identifier:[ \t]+(app\.kernova($|\.)|com\.kernova\.app$)/ {
            if (path != "") print path
        }
    ' | sort -u
}

# unregister_apps_in <dir> — unregister every bundle under <dir> from Launch
# Services, leaving the files. A missing <dir> unregisters nothing.
unregister_apps_in() {
    local app
    while IFS= read -r app; do
        lsregister -u "$app" >/dev/null 2>&1
    done < <(find "$1" -maxdepth 6 -name '*.app' -type d 2>/dev/null)
}

# evict_arena <dir> — unregister every bundle in a build arena, then delete it;
# succeeds when <dir> is gone. Deleted rather than trashed: a bundle in the
# Trash is still an on-disk copy Launch Services can rediscover and elect, and
# an arena holds only build products its checkout regenerates.
evict_arena() {
    unregister_apps_in "$1"
    rm -rf "$1" 2>/dev/null
    [ ! -e "$1" ]
}

# evict_build_server_cache <dir> — delete one xcode-build-server cache: index
# data its checkout regenerates.
evict_build_server_cache() {
    rm -rf "$1" 2>/dev/null
    [ ! -e "$1" ]
}

# derived_data_root — the directory holding the machine's per-path-hashed
# arenas (Tools/derived-data-path.sh --root); prints nothing when none exists.
derived_data_root() {
    "$build_arenas_root/Tools/derived-data-path.sh" --root 2>/dev/null || true
}

# labeled_path <path> — the path, then the checkout its arena belongs to in
# parentheses when Tools/arena-label.sh can name one.
labeled_path() {
    local label
    label=$("$build_arenas_root/Tools/arena-label.sh" "$1" 2>/dev/null) || label=''
    if [ -n "$label" ]; then
        printf '%s (%s)' "$(pretty_path "$1")" "$label"
    else
        pretty_path "$1"
    fi
}

# arenas_with_status <root> <status>... — one line per Kernova arena directly
# under <root> whose Tools/arena-label.sh --status is one of <status>. Xcode
# names an arena `<project>-<hash>`, so the prefix selects this project's.
arenas_with_status() {
    local root=$1 dir status want
    shift
    [ -n "$root" ] || return 0
    for dir in "$root"/Kernova-*/; do
        dir=${dir%/}
        [ -d "$dir" ] || continue
        status=$("$build_arenas_root/Tools/arena-label.sh" --status "$dir" 2>/dev/null) || continue
        for want in "$@"; do
            [ "$status" = "$want" ] && printf '%s\n' "$dir" && break
        done
    done
}
