#!/usr/bin/env bash
# The build-arena operations the build pipeline runs. `make ghosts` reports on
# the same debris across the machine (Tools/ghosts.sh).
#
# Usage: Tools/build-arenas.sh clean | sweep | unregister <dir>
#
#   clean             Remove the DerivedData/ of the checkout holding this
#                     script, where every `make` build of it lands, after
#                     unregistering its bundles. Exits non-zero naming what is
#                     left when a process holds it or the removal leaves
#                     something behind. `make clean` runs it under the
#                     checkout's build lock.
#   sweep             Unregister the Launch Services records whose bundle is
#                     gone — a removed worktree's builds leave theirs — and
#                     evict the xcode-build-server caches of this clone's
#                     checkouts that are gone. Skips anything a process holds,
#                     and always exits 0: Tools/worktree-setup.sh runs it on
#                     every new worktree.
#   unregister <dir>  Unregister every bundle under <dir> from Launch Services,
#                     leaving the files; a missing <dir> is a no-op.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/output.sh
. "$REPO_ROOT/Tools/lib/output.sh"
# shellcheck source=lib/worktrees.sh
. "$REPO_ROOT/Tools/lib/worktrees.sh"
# shellcheck source=lib/build-arenas.sh
. "$REPO_ROOT/Tools/lib/build-arenas.sh"

usage() {
    printf 'Usage: Tools/build-arenas.sh clean | sweep | unregister <dir>\n' >&2
    exit 2
}

# Absolute, because Launch Services records bundles by absolute path.
absolute() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

clean() {
    local dir="$REPO_ROOT/DerivedData" line
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        printf 'No build arena of this checkout to remove\n'
        return 0
    fi
    # Before any removal, so nothing goes while a process runs from it.
    refresh_holders "$dir"
    if path_held "$dir"; then
        printf 'build-arenas.sh: cannot remove %s\n' "$(pretty_path "$dir")" >&2
        while IFS= read -r line; do
            printf 'build-arenas.sh: %s\n' "$line" >&2
        done < <(holder_blocked_lines "$dir")
        exit 1
    fi
    printf 'Removing build arena %s — %s\n' "$(pretty_path "$dir")" "$(disk_size "$dir")"
    if ! evict_arena "$dir"; then
        printf 'build-arenas.sh: failed to remove %s\n' "$(pretty_path "$dir")" >&2
        exit 1
    fi
}

sweep() {
    local path dir cache_root="$HOME/Library/Caches/xcode-build-server"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] && continue
        lsregister -u "$path" >/dev/null 2>&1
        printf 'build-arenas.sh: swept dead Launch Services registration: %s\n' "$path"
    done < <(kernova_registered_paths)

    [ -d "$cache_root" ] || return 0
    read_worktree_layout "$REPO_ROOT" || return 0
    refresh_holders "$cache_root"
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
