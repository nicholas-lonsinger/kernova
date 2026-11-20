#!/usr/bin/env bash
# The build-arena operations the build pipeline runs. `make ghosts` reports on
# the same debris across the machine (Tools/ghosts.sh).
#
# Usage: Tools/build-arenas.sh clean | sweep | unregister <dir>
#
#   clean             Remove the build arenas of the checkout holding this
#                     script: its DerivedData/, and every Kernova-<hash> arena
#                     in Xcode's machine-wide DerivedData folder that records
#                     this checkout's project, or that holds only a package
#                     resolution under the name Xcode gives that project.
#                     Nothing else: a build location set any other way is out
#                     of its reach. Names each arena it removes, and exits
#                     non-zero naming what is left when a process holds one or
#                     a removal leaves one behind. `make clean` runs it under
#                     the checkout's build lock.
#   sweep             Unregister the Launch Services records whose bundle is
#                     gone, evict the build arenas of this clone's worktrees
#                     that git no longer registers and whose project is gone,
#                     and the xcode-build-server caches of this clone's
#                     checkouts that are gone. Skips anything a
#                     process holds, and always exits 0: Tools/worktree-setup.sh
#                     runs it on every new worktree.
#   unregister <dir>  Unregister every bundle under <dir> from Launch Services,
#                     leaving the files; a missing <dir> is a no-op.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/output.sh
. "$REPO_ROOT/Tools/lib/output.sh"
# shellcheck source=lib/worktrees.sh
. "$REPO_ROOT/Tools/lib/worktrees.sh"
# shellcheck source=lib/arena-records.sh
. "$REPO_ROOT/Tools/lib/arena-records.sh"
# shellcheck source=lib/build-arenas.sh
. "$REPO_ROOT/Tools/lib/build-arenas.sh"

usage() {
    printf 'Usage: Tools/build-arenas.sh clean | sweep | unregister <dir>\n' >&2
    exit 2
}

die() {
    printf 'build-arenas.sh: %s\n' "$1" >&2
    exit 1
}

# Absolute, because Launch Services records bundles by absolute path.
absolute() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

# own_arenas <root> — one line per arena directly under <root> that belongs to
# this checkout: named Kernova-<28 letters>, and recording this checkout's
# project, or holding only a package resolution under the name
# Tools/derived-data-path.sh gives that project.
own_arenas() {
    local root=$1 project="$REPO_ROOT/Kernova.xcodeproj" named dir recorded
    [ -n "$root" ] || return 0
    named=$("$REPO_ROOT/Tools/derived-data-path.sh" "$project" 2>/dev/null) || named=''
    for dir in "$root"/Kernova-*; do
        [[ ${dir##*/} =~ ^Kernova-[a-z]{28}$ ]] && [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        if recorded=$(arena_recorded_project "$dir"); then
            [ "$recorded" -ef "$project" ] && printf '%s\n' "$dir"
        elif [ "$dir" = "$named" ] && arena_holds_only_packages "$dir"; then
            printf '%s\n' "$dir"
        fi
    done
}

clean() {
    local root targets=() dir held=0 line
    root=$(derived_data_root)
    if [ -e "$REPO_ROOT/DerivedData" ] || [ -L "$REPO_ROOT/DerivedData" ]; then
        targets+=("$REPO_ROOT/DerivedData")
    fi
    while IFS= read -r dir; do
        targets+=("$dir")
    done < <(own_arenas "$root")
    if [ -z "$root" ]; then
        printf 'Xcode keeps no machine-wide DerivedData folder here, so clean looks only at %s\n' \
            "$(pretty_path "$REPO_ROOT/DerivedData")"
    fi
    if [ "${#targets[@]}" -eq 0 ]; then
        printf 'No build arena of this checkout to remove\n'
        return 0
    fi

    # Every refusal before any removal, so a refusal never follows a
    # "Removing…" line, and nothing goes while a process runs from what stays.
    refresh_holders "${targets[@]}"
    for dir in "${targets[@]}"; do
        path_held "$dir" || continue
        held=1
        printf 'build-arenas.sh: cannot remove %s\n' "$(labeled_path "$dir")" >&2
        while IFS= read -r line; do
            printf 'build-arenas.sh: %s\n' "$line" >&2
        done < <(holder_blocked_lines "$dir")
    done
    [ "$held" = 0 ] || exit 1

    for dir in "${targets[@]}"; do
        printf 'Removing build arena %s — %s\n' "$(labeled_path "$dir")" "$(disk_size "$dir")"
        evict_arena "$dir" || die "failed to remove $(pretty_path "$dir")"
    done
}

sweep() {
    local path dir root roots=() cache_root="$HOME/Library/Caches/xcode-build-server"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] && continue
        lsregister -u "$path" >/dev/null 2>&1
        printf 'build-arenas.sh: swept dead Launch Services registration: %s\n' "$path"
    done < <(kernova_registered_paths)

    root=$(derived_data_root)
    [ -n "$root" ] && roots+=("$root")
    [ -d "$cache_root" ] && roots+=("$cache_root")
    [ "${#roots[@]}" -gt 0 ] && refresh_holders "${roots[@]}"
    # Only `worktree-removed`: the one status whose checkout is certainly gone.
    # Every other checkout, removed-looking or not, may be on a volume that is
    # not mounted, in a folder this process may not read, or a clone this one
    # does not list.
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        path_held "$dir" && continue
        # Labeled first: the label is read out of the arena's own records.
        path=$(labeled_path "$dir")
        evict_arena "$dir" && printf 'build-arenas.sh: evicted orphaned DerivedData arena: %s\n' "$path"
    done < <(arenas_with_status "$root" worktree-removed)

    read_worktree_layout "$REPO_ROOT" || return 0
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        path_held "$dir" && continue
        evict_build_server_cache "$dir" &&
            printf 'build-arenas.sh: evicted stale xcode-build-server cache: %s\n' "$(pretty_path "$dir")"
    done < <(stale_build_server_caches "$cache_root")
}

case "${1:-}" in
    clean)
        [ $# -eq 1 ] || usage
        clean
        ;;
    sweep)
        [ $# -eq 1 ] || usage
        sweep
        exit 0
        ;;
    unregister)
        [ $# -eq 2 ] && [ -n "$2" ] || usage
        unregister_apps_in "$(absolute "$2")"
        ;;
    *) usage ;;
esac
