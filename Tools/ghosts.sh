#!/usr/bin/env bash
# Find (and optionally clean up) ghost Kernova registrations left behind by
# worktrees that were torn down without going through Claude Code's
# ExitWorktree unregister hook (a manual `git worktree remove`, dragging the
# worktree to Trash, etc.).
#
# Both KernovaFileProvider (host) and KernovaMacOSAgentFileProvider (guest
# agent) are ordinary macOS/arm64 .appex bundles — nothing about them is
# "guest-only" at the bundle level, that's purely a deployment-time decision.
# So the moment Xcode builds one into a worktree's DerivedData, Launch
# Services' filesystem scanner discovers and registers it, regardless of
# where the binary is ultimately meant to run. If the worktree directory is
# then removed by hand, that registration is never unregistered and lingers
# pointing at a path that no longer resolves.
#
# Checks for:
#   - Launch Services registrations for app.kernova.* extensions whose
#     `path:` no longer exists on disk
#   - Running processes executing from a Kernova path that no longer exists
#     on disk (the file was deleted out from under a still-running process)
#   - `git worktree list` entries marked `prunable` (administrative metadata
#     for a worktree whose directory is already gone)
#
# Run via `make ghosts` (report only) or `make clean-ghosts` (also fixes).
# Direct invocation: Tools/ghosts.sh [--fix]

set -uo pipefail

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# ---- output helpers (matches Tools/doctor.sh) --------------------------------

if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yellow=$'\033[0;33m'
    c_dim=$'\033[0;90m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_yellow=''; c_dim=''; c_bold=''; c_reset=''
fi

found_count=0
fixed_count=0

clean()   { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
ghost()   { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; found_count=$((found_count + 1)); }
fixed()   { printf '    %s→ fixed:%s %s\n' "$c_green" "$c_reset" "$1"; fixed_count=$((fixed_count + 1)); }
detail()  { printf '    %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
section() { printf '\n%s%s%s\n' "$c_bold" "$1" "$c_reset"; }

printf '%sKernova ghost cleanup%s\n' "$c_bold" "$c_reset"
[ "$FIX" = 1 ] && printf '%s(--fix: will unregister, kill, and prune)%s\n' "$c_dim" "$c_reset"

# ---- Launch Services ghost registrations -------------------------------------

section 'Launch Services registrations'

# lsregister's dump lists `path:` a few lines before the `identifier:` line
# for the same entry, with entries separated by a full-width dash rule —
# track the most recently seen path and reset it at each rule so an
# identifier never gets paired with a path from a different entry.
kernova_registered_paths() {
    "$LSREGISTER" -dump 2>/dev/null | awk '
        /^-+$/ { path = "" }
        /^path:/ {
            line = $0
            sub(/^path:[ \t]*/, "", line)
            sub(/ \(0x[0-9a-fA-F]+\)[ \t]*$/, "", line)
            path = line
        }
        /^identifier:[ \t]+app\.kernova($|\.)/ {
            if (path != "") print path
        }
    ' | sort -u
}

# Built via a plain read loop rather than `mapfile`/`readarray`: macOS ships
# bash 3.2 (GPLv3), which predates both builtins.
live_ghost_paths=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && continue
    live_ghost_paths+=("$path")
done < <(kernova_registered_paths)

if [ "${#live_ghost_paths[@]}" -eq 0 ]; then
    clean 'No ghost app.kernova.* registrations found'
else
    for path in "${live_ghost_paths[@]}"; do
        ghost "Registered but missing on disk: $path"
    done

    if [ "$FIX" = 1 ]; then
        # Best-effort pass: unregistering a bundle cascades to its embedded
        # plugins, so a later -u call on an already-cascaded child path (e.g.
        # a .appex under a .app that was just unregistered) reports failure
        # even though the record is already gone. Don't trust individual exit
        # codes — attempt all of them, then re-dump once and check what's
        # actually still registered.
        for path in "${live_ghost_paths[@]}"; do
            "$LSREGISTER" -u "$path" >/dev/null 2>&1
        done

        still_registered=$(kernova_registered_paths)
        for path in "${live_ghost_paths[@]}"; do
            if printf '%s\n' "$still_registered" | grep -qxF "$path"; then
                detail "still registered: $path"
                detail 'A full `lsregister -kill -r -domain local -domain user` rebuild would clear it, but that resets ALL app registrations system-wide, not just Kernova, so this script will not do that for you.'
            else
                fixed "unregistered: $path"
            fi
        done
    fi
fi

# ---- orphaned processes ------------------------------------------------------

section 'Running processes'

proc_found=0
while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    # The `txt` fd in lsof's field output is the process's own executable —
    # if that path no longer resolves, the file was deleted (or moved to
    # Trash) while the process was still running from it.
    exe_path=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -z "$exe_path" ] && continue
    [ -e "$exe_path" ] && continue
    proc_found=1
    ghost "PID $pid running from a deleted path: $exe_path"
    if [ "$FIX" = 1 ]; then
        if kill "$pid" 2>/dev/null; then
            fixed "killed PID $pid"
        else
            detail "kill failed for PID $pid (already gone?)"
        fi
    fi
done < <(pgrep -f -i kernova 2>/dev/null)

[ "$proc_found" -eq 0 ] && clean 'No orphaned Kernova processes found'

# ---- stale git worktrees ------------------------------------------------------

section 'Git worktrees'

prunable=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep 'prunable' || true)
if [ -z "$prunable" ]; then
    clean 'No prunable git worktrees'
else
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ghost "Prunable worktree: $line"
    done <<< "$prunable"
    if [ "$FIX" = 1 ]; then
        if git -C "$REPO_ROOT" worktree prune -v >/dev/null 2>&1; then
            fixed 'pruned stale worktree metadata'
        else
            detail 'git worktree prune failed'
        fi
    fi
fi

# ---- summary ------------------------------------------------------------------

section 'Summary'

if [ "$found_count" -eq 0 ]; then
    printf '%sNothing to clean up.%s\n' "$c_green" "$c_reset"
    exit 0
fi

if [ "$FIX" = 1 ]; then
    printf '%d issue(s) found, %d fixed.\n' "$found_count" "$fixed_count"
    [ "$fixed_count" -lt "$found_count" ] && exit 1
    exit 0
else
    printf '%s%d issue(s) found.%s Re-run with %s--fix%s (or `make clean-ghosts`) to clean them up.\n' \
        "$c_yellow" "$found_count" "$c_reset" "$c_bold" "$c_reset"
    exit 1
fi
