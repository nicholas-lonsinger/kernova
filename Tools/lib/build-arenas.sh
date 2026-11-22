# Build arenas and the Launch Services records of the bundles built into them,
# for Tools/build-arenas.sh and Tools/ghosts.sh. Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/build-arenas.sh"

# shellcheck shell=bash

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

# xcode_derived_data_root — the folder the Xcode app builds each project into
# under a hashed name: its derived-data preference when that is a path, Xcode's
# default when unset. Prints nothing when the preference names a folder inside
# each project instead.
xcode_derived_data_root() {
    local pref
    pref=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null) || pref=''
    case "$pref" in
        '') printf '%s/Library/Developer/Xcode/DerivedData' "$HOME" ;;
        /*) printf '%s' "${pref%/}" ;;
    esac
}

# xcode_kernova_arenas — one line per Kernova build arena in that folder.
xcode_kernova_arenas() {
    local root dir
    root=$(xcode_derived_data_root)
    [ -n "$root" ] || return 0
    for dir in "$root"/Kernova-*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && printf '%s\n' "$dir"
    done
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
