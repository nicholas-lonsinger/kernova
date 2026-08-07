#!/usr/bin/env bash
# Find (and optionally clean up) ghost Kernova registrations left behind by
# torn-down worktrees (Claude Code's session-end auto-removal of a clean
# worktree, a manual `git worktree remove`, dragging the worktree to Trash,
# etc.).
#
# The moment Xcode builds an app bundle into a worktree's DerivedData, Launch
# Services' filesystem scanner discovers and registers it — the guest agent
# included, since nothing about that bundle is "guest-only" at the bundle
# level. If the worktree directory is then removed by hand, that registration
# is never unregistered and lingers pointing at a path that no longer resolves.
#
# Checks for:
#   - Launch Services registrations whose `path:` no longer exists on disk,
#     under the current app.kernova.* identifiers and the legacy
#     pre-#471-rename `com.kernova.app` one alike
#   - Xcode DerivedData build arenas in the global per-path-hashed
#     ~/Library location whose recorded source worktree no longer exists —
#     on default-location machines every worktree the GUI opens leaves a
#     permanent, LS-registered app copy there that keeps competing in the
#     version election after the worktree is torn down (docs/BUILD.md
#     "Derived data and build arenas")
#   - Running processes executing from a Kernova path that no longer exists
#     on disk (the file was deleted out from under a still-running process)
#   - `git worktree list` entries marked `prunable` (administrative metadata
#     for a worktree whose directory is already gone)
#   - LIVE on-disk Kernova.app copies (Trash, DerivedData) whose
#     CFBundleVersion outranks the installed /Applications copy — unlike the
#     dead-path ghosts above, Launch Services elects these by highest
#     CFBundleVersion (= squash-aware git commit count, see docs/BUILD.md "Build
#     version"), so a ghost build can shadow the real app indefinitely even
#     though version ordering can never favor the installed copy on its own
#     (#454). Deregistration/eviction is the only lever.
#
# Run via `make ghosts` (report only) or `make clean-ghosts` (also fixes).
# Direct invocation: Tools/ghosts.sh [--fix | --sweep | --evict <dir>]
set -uo pipefail

FIX=0
SWEEP=0
EVICT=0
EVICT_DIR=
# No argument is the report mode, so '' is an arm rather than falling to *).
# Printed with plain printf, not the lib's helpers: output.sh is sourced below,
# after this dispatch, so a bad flag can be rejected before anything else runs.
usage='Usage: Tools/ghosts.sh [--fix | --sweep | --evict <dir>]'
case "${1:-}" in
    '') ;;
    --fix) FIX=1 ;;
    --sweep) SWEEP=1 ;;
    --evict)
        EVICT=1
        EVICT_DIR="${2:-}"
        ;;
    -h | --help)
        printf '%s\n' "$usage"
        exit 0
        ;;
    *)
        printf 'ghosts.sh: unknown option %s\n%s\n' "$1" "$usage" >&2
        exit 2
        ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Sourced here, before anything prints: the --sweep and --evict modes below run
# and exit long before the report body, and they label paths too.
# shellcheck source=lib/output.sh
. "$REPO_ROOT/Tools/lib/output.sh"

# ---- path display -------------------------------------------------------------

# The path plus the checkout its build arena belongs to. A default-mode arena is
# named by a hash of the .xcodeproj path (Kernova-cylpmrailymlsackwzjwvurxnpbj),
# so on its own no arena line answers the first question a reader has — whose
# build is this? Tools/arena-label.sh resolves the hash back to a worktree name;
# it exits non-zero for anything it can't attribute, and then the path renders
# bare exactly as before.
labeled_path() {
    local label
    label=$("$REPO_ROOT/Tools/arena-label.sh" "$1" 2>/dev/null) || label=''
    if [ -n "$label" ]; then
        printf '%s (%s)' "$(pretty_path "$1")" "$label"
    else
        pretty_path "$1"
    fi
}

# lsregister's dump lists `path:` a few lines before the `identifier:` line
# for the same entry, with entries separated by a full-width dash rule —
# track the most recently seen path and reset it at each rule so an
# identifier never gets paired with a path from a different entry.
#
# Both identifier eras match: the current `app.kernova*` one and the legacy
# `com.kernova.app` left by builds predating the #471 naming cleanup.
kernova_registered_paths() {
    "$LSREGISTER" -dump 2>/dev/null | awk '
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

# Xcode DerivedData arenas left by torn-down worktrees. Where the machine's
# preference puts per-path-hashed arenas, every worktree the GUI opens gets a
# permanent folder there — nothing removes it when the worktree goes away, and
# the LS-registered app copy inside keeps competing in the CFBundleVersion
# election (docs/BUILD.md "Derived data and build arenas").
#
# Resolved rather than hardcoded to the default ~/Library path: on a machine
# pointed at a custom root, hardcoding scanned a directory Xcode never writes
# to, so the sweep reported no orphans while they piled up unseen. Empty means
# no machine-wide arena directory exists at all — Relative mode nests each arena
# inside its own checkout, where it cannot outlive the worktree, so there is
# genuinely nothing to scan.
XCODE_DD_ROOT=$("$REPO_ROOT/Tools/derived-data-path.sh" --root 2>/dev/null) || XCODE_DD_ROOT=''

# Print one arena directory per line whose recorded source worktree is gone.
# The classification is Tools/arena-label.sh's — this used to re-read each
# info.plist and re-derive the .claude/worktrees layout itself, which was the
# same mapping implemented twice. --status is asked for rather than the human
# label so nothing here depends on that label's wording. Scoped to this repo's
# worktrees by that same classification: a deleted checkout of some other
# project reports `other` and is not this script's call to clean up.
orphaned_dd_arenas() {
    [ -n "$XCODE_DD_ROOT" ] || return 0
    local info dir
    for info in "$XCODE_DD_ROOT"/*/info.plist; do
        [ -f "$info" ] || continue
        dir=${info%/info.plist}
        [ "$("$REPO_ROOT/Tools/arena-label.sh" --status "$dir" 2>/dev/null)" = 'worktree-removed' ] || continue
        printf '%s\n' "$dir"
    done
}

# PIDs of processes executing from inside the arena — eviction would yank
# their binaries out from under them.
# Not pgrep: `pgrep -f` takes a regex, and the arena path must match
# literally (`grep -F`); a false match only skips an eviction, the safe
# failure mode.
arena_pids() {
    # shellcheck disable=SC2009
    ps -axo pid=,args= 2>/dev/null | grep -F "$1/" | grep -v grep | awk '{print $1}'
}

arena_in_use() {
    [ -n "$(arena_pids "$1")" ]
}

# The process's own executable path. lsof's `txt` fd is the mapped binary,
# which is the only reliable source here: the arena holds bundles whose paths
# contain spaces ("Kernova Guest Agent.app"), so splitting `ps` args on
# whitespace would truncate them.
exe_of_pid() {
    lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# The in-use refusal: one line naming each blocking process, then the way out.
# Naming the PID is what makes the refusal actionable — the arena path says
# which folder is stuck, never which running thing to go quit.
#
# When the app itself is the blocker, its AppleScript quit is the one to reach
# for: it save-suspends running guests before exiting, where a signal drops
# them unsaved and ⌘Q closes the windows but leaves the app resident, so the
# arena stays busy and the next run refuses again for the same reason.
# Callers check arena_in_use first; with no blocker this prints the tail line
# alone, which is the harmless read on a process that exited in between.
arena_blocked_lines() {
    local pid exe is_app=0
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        exe=$(exe_of_pid "$pid")
        printf 'still running from inside: PID %s%s\n' "$pid" "${exe:+ (${exe##*/})}"
        case "$exe" in */Kernova.app/Contents/MacOS/Kernova) is_app=1 ;; esac
    done < <(arena_pids "$1")
    if [ "$is_app" = 1 ]; then
        printf 'quit it, then re-run: %s (save-suspends running VMs)\n' \
            "osascript -e 'quit app \"Kernova\"'"
    else
        printf 'quit it (or reboot), then re-run\n'
    fi
}

# Unregister every bundle inside the arena, then delete the folder outright.
# Unregister first, so no dead registration lingers until the next sweep.
# `rm -rf`, not `trash` (the exception to the trash-first file-operations
# rule): a bundle sitting in the Trash is still a valid on-disk copy that
# Launch Services can rediscover and re-elect until the Trash is emptied,
# so trashing just relocates the ghost — and an orphaned arena is
# purely regenerable build products of a worktree that no longer exists,
# with nothing user-authored to recover.
evict_dd_arena() {
    local dir=$1 app
    while IFS= read -r app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1
    done < <(find "$dir" -maxdepth 6 -name '*.app' -type d 2>/dev/null)
    rm -rf "$dir" 2>/dev/null
}

# --sweep: the quiet, non-interactive subset for hooks — unregister dead
# app.kernova.* Launch Services registrations, evict DerivedData arenas
# orphaned by torn-down worktrees, and exit. The post-checkout git hook runs
# it on every new worktree, so debris left by torn-down worktrees self-heals
# at the next worktree creation. Best-effort by design: always exits 0 so a
# failed sweep can never fail the checkout that triggered it, skips anything
# a process is still running from, and skips the fix path's re-dump
# verification — `make ghosts` still reports anything left behind. Unlike
# --fix it terminates nothing: --fix kills processes whose own binary is
# already deleted, while an arena's live blocker is the user's to quit under
# either flag. The sweep runs unattended from a git hook, and the next
# worktree creation sweeps again.
if [ "$SWEEP" = 1 ]; then
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        [ -e "$path" ] && continue
        "$LSREGISTER" -u "$path" >/dev/null 2>&1
        printf 'ghosts.sh: swept dead Launch Services registration: %s\n' "$path"
    done < <(kernova_registered_paths)
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        arena_in_use "$dir" && continue
        if evict_dd_arena "$dir"; then
            printf 'ghosts.sh: evicted orphaned DerivedData arena: %s\n' "$(labeled_path "$dir")"
        fi
    done < <(orphaned_dd_arenas)
    exit 0
fi

# ---- output helpers (matches Tools/doctor.sh) --------------------------------

found_count=0
fixed_count=0

# section/pass/warn/value/detail/pretty_path come from Tools/lib/output.sh.
# These two stay local because they also drive this script's summary counters.
ghost() { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; found_count=$((found_count + 1)); }
fixed() { printf '    %s→ fixed:%s %s\n' "$c_green" "$c_reset" "$1"; fixed_count=$((fixed_count + 1)); }

# --evict <dir>: remove ONE build arena and exit — the shared implementation
# behind `make clean`. The in-use guard matches --fix: a process running from
# the arena is the user's to quit, so the arena is left intact and this exits
# non-zero rather than deleting a binary out from under it. A path that isn't
# there is a no-op, so callers can pass every candidate arena unconditionally.
if [ "$EVICT" = 1 ]; then
    if [ -z "$EVICT_DIR" ]; then
        printf 'ghosts.sh: --evict requires a directory argument\n' >&2
        exit 2
    fi
    # Absolutize: callers pass repo-relative arenas (the in-worktree
    # DerivedData/), and the in-use check greps absolute paths out of `ps` —
    # a relative path would silently never match, defeating the guard.
    case "$EVICT_DIR" in
        /*) ;;
        *) EVICT_DIR="$PWD/$EVICT_DIR" ;;
    esac
    [ -d "$EVICT_DIR" ] || exit 0
    # Clear the in-use guard before announcing anything, so a refusal never
    # follows a "Removing…" line that turned out to be false.
    if arena_in_use "$EVICT_DIR"; then
        printf 'ghosts.sh: cannot remove %s\n' "$(labeled_path "$EVICT_DIR")" >&2
        while IFS= read -r blocked; do
            printf 'ghosts.sh: %s\n' "$blocked" >&2
        done < <(arena_blocked_lines "$EVICT_DIR")
        exit 1
    fi
    # Size on the way out: on a default-location machine this is the arena the
    # Xcode GUI shares, so discarding it costs a full rebuild — worth seeing as
    # it happens rather than wondering later why the next build was cold.
    printf 'Removing build arena %s — %s\n' \
        "$(labeled_path "$EVICT_DIR")" \
        "$(du -sh "$EVICT_DIR" 2>/dev/null | cut -f1)"
    evict_dd_arena "$EVICT_DIR"
    if [ -d "$EVICT_DIR" ]; then
        printf 'ghosts.sh: failed to remove %s\n' "$(labeled_path "$EVICT_DIR")" >&2
        exit 1
    fi
    exit 0
fi

printf '%sKernova ghost cleanup%s\n' "$c_bold" "$c_reset"
# Names the mode, not the flag that selected it: the flag is unreachable through
# the Makefile front door anyway (make swallows `--fix` as one of its own
# options and bails), so echoing it back only suggests an argument the reader
# cannot actually pass to `make ghosts`.
[ "$FIX" = 1 ] && printf '%s(repair mode: will unregister, kill, and prune)%s\n' "$c_dim" "$c_reset"

# ---- Launch Services ghost registrations -------------------------------------

section 'Launch Services registrations'

# Built via a plain read loop rather than `mapfile`/`readarray`: macOS ships
# bash 3.2 (GPLv3), which predates both builtins.
live_ghost_paths=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && continue
    live_ghost_paths+=("$path")
done < <(kernova_registered_paths)

if [ "${#live_ghost_paths[@]}" -eq 0 ]; then
    pass 'No ghost app.kernova.* or legacy com.kernova.app registrations found'
else
    for path in "${live_ghost_paths[@]}"; do
        ghost "Registered but missing on disk: $path"
    done

    if [ "$FIX" = 1 ]; then
        # Best-effort pass: an individual `lsregister -u` exit code does not
        # track whether the record actually went away. Attempt all of them,
        # then re-dump once and check what is still registered.
        for path in "${live_ghost_paths[@]}"; do
            "$LSREGISTER" -u "$path" >/dev/null 2>&1
        done

        still_registered=$(kernova_registered_paths)
        for path in "${live_ghost_paths[@]}"; do
            if printf '%s\n' "$still_registered" | grep -qxF "$path"; then
                detail "still registered: $path"
                detail 'Unexpected — a plain `lsregister -u` normally sticks even once the path is gone (verified empirically 2026-07-08). Re-run this script; if it persists, file a bug rather than reaching for `lsregister -kill` (removed on current macOS).'
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
    # If the process's own executable no longer resolves, the file was
    # deleted (or moved to Trash) while it was still running from it.
    exe_path=$(exe_of_pid "$pid")
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

[ "$proc_found" -eq 0 ] && pass 'No orphaned Kernova processes found'

# ---- stale git worktrees ------------------------------------------------------

section 'Git worktrees'

prunable=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep 'prunable' || true)
if [ -z "$prunable" ]; then
    pass 'No prunable git worktrees'
else
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ghost "Prunable worktree: $line"
    done <<< "$prunable"
    if [ "$FIX" = 1 ]; then
        if git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1; then
            fixed 'pruned stale worktree metadata'
        else
            detail 'git worktree prune failed'
        fi
    fi
fi

# ---- orphaned DerivedData build arenas ----------------------------------------

section 'DerivedData build arenas'

# Unlike the live-copy election check below (which prompts, because a live
# copy might be wanted), an orphaned arena's source worktree is gone — its
# build products are unreachable garbage, so --fix evicts without asking.
# An arena a process is still running from is skipped with a pointer instead,
# since quitting a possibly-in-use app is not this script's call.
dd_orphans=()
while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    dd_orphans+=("$dir")
done < <(orphaned_dd_arenas)

if [ "${#dd_orphans[@]}" -eq 0 ]; then
    pass 'No DerivedData arenas left by torn-down worktrees'
else
    for dir in "${dd_orphans[@]}"; do
        # Resolved once, up front, because the label is read out of the arena's
        # own info.plist — evicting the arena destroys the evidence, so a
        # lookup after the delete falls back to the bare hashed path on the one
        # line where naming the worktree matters most.
        dir_label=$(labeled_path "$dir")
        ghost "Orphaned arena: $dir_label — $(du -sh "$dir" 2>/dev/null | cut -f1)"
        if arena_in_use "$dir"; then
            while IFS= read -r blocked; do
                detail "$blocked"
            done < <(arena_blocked_lines "$dir")
            continue
        fi
        if [ "$FIX" = 1 ]; then
            if evict_dd_arena "$dir"; then
                fixed "unregistered bundles and deleted: $dir_label"
            else
                detail "delete failed for $dir_label"
            fi
        fi
    done
fi

# ---- live on-disk copies & Launch Services election --------------------------

section 'On-disk copies & registration election'

# Trash and DerivedData are walked explicitly because both escape
# `mdfind` — DerivedData ships a `.metadata_never_index` sentinel and Trash is
# excluded from Spotlight entirely.
#
# Index.noindex/ is filtered out. Index-while-building writes a second products
# tree there, so an arena yields two Kernova.app paths and the section reported
# the same arena twice. The index copy is not a competing build: it carries no
# Info.plist and no executable (10M of skeleton against the real product's 76M),
# so it has no CFBundleVersion to enter the election with, and LaunchServices
# does not register it — verified 2026-07-24 against an arena holding both,
# where the `lsregister -dump` entries covered only Build/Products/. Excluded by
# path rather than by "has no Info.plist", so that a *registered* bundle which
# is genuinely malformed still gets surfaced instead of silently dropped.
kernova_app_copies() {
    {
        mdfind "kMDItemCFBundleIdentifier == 'app.kernova'" 2>/dev/null
        find "$HOME/.Trash" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        # Same resolved root as the orphan scan above, for the same reason; the
        # in-checkout DerivedData/ below covers Relative mode, where the
        # machine-wide root does not exist.
        if [ -n "$XCODE_DD_ROOT" ]; then
            find "$XCODE_DD_ROOT" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        fi
        find "$REPO_ROOT/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
    } | grep -v '/Index\.noindex/' | sort -u
}

app_copies=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && app_copies+=("$path")
done < <(kernova_app_copies)

# Unlike the dead-path ghost check above, this reports the LIVE copies — the
# ones that still exist on disk but sit outside /Applications. Launch Services
# elects a handler by highest CFBundleVersion (a squash-aware git commit count — see
# docs/BUILD.md "Build version"), so a ghost build with a higher count can shadow
# the real app indefinitely; version ordering can never fix this on its own,
# eviction is the only lever (#454).
bundle_version() {
    plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

# Ad-hoc vs. a real identity, so two same-named copies can be told apart.
signing_summary() {
    local info team
    info=$(codesign -dv --verbose=2 "$1" 2>&1)
    if printf '%s' "$info" | grep -q '^Signature=adhoc'; then
        printf 'ad-hoc'
        return
    fi
    team=$(printf '%s' "$info" | sed -n 's/^TeamIdentifier=//p')
    if [ -n "$team" ] && [ "$team" != "not set" ]; then
        printf 'team %s' "$team"
    else
        printf 'identity'
    fi
}

# is_numeric VALUE -> 0 (true) when VALUE is a plain non-empty integer.
is_numeric() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# location_of PATH — the directory a bundle is elected from, and the key this
# section groups by. Xcode nests an arena's products under
# Build/Products/<config>/, and every bundle produced by one build shares that
# prefix, so cutting there collapses a whole arena into a single block. Anything else groups by its containing directory
# (/Applications, ~/.Trash).
location_of() {
    local rest
    case "$1" in
        */Build/Products/*)
            rest=${1#*/Build/Products/}
            printf '%s/Build/Products/%s' "${1%%/Build/Products/*}" "${rest%%/*}"
            ;;
        *) dirname "$1" ;;
    esac
}

# Rendering state, held as parallel arrays: macOS ships bash 3.2, which has no
# associative arrays, so locations are interned by linear search into loc_paths
# and every item records its location's index. Nothing here prints — the whole
# section is computed first so the verdict lines can lead and the per-location
# blocks follow, instead of interleaving findings with detail.
loc_paths=()
item_loc=()
item_name=()
item_meta=()
item_mark=()

# Returns through a global rather than stdout: interning has to APPEND to
# loc_paths, and a `$(loc_index …)` call would run that append in a subshell,
# where the new entry dies with the substitution and every block silently
# disappears from the report.
loc_index_result=''
loc_index() {
    local want=$1 n
    for (( n = 0; n < ${#loc_paths[@]}; n++ )); do
        if [ "${loc_paths[$n]}" = "$want" ]; then
            loc_index_result=$n
            return
        fi
    done
    loc_paths+=("$want")
    loc_index_result=$(( ${#loc_paths[@]} - 1 ))
}

# add_item <path> <display-name> <meta> <mark>; mark is '', 'ok' or 'ghost'.
add_item() {
    loc_index "$(location_of "$1")"
    item_loc+=("$loc_index_result")
    item_name+=("$2")
    item_meta+=("$3")
    item_mark+=("$4")
}

copies_verdict=''
copies_verdict_kind=''
competing_copies=()

if [ "${#app_copies[@]}" -eq 0 ]; then
    copies_verdict='No on-disk Kernova.app copies found'
    copies_verdict_kind='clean'
else
    # Check the well-known path directly rather than scanning app_copies for
    # it: blessed_path is a fixed constant, so a scan would just be a second
    # plutil spawn for the same bundle the equality check already identifies.
    blessed_path='/Applications/Kernova.app'
    blessed_version=''
    [ -e "$blessed_path" ] && blessed_version=$(bundle_version "$blessed_path")
    blessed_known=0
    is_numeric "$blessed_version" && blessed_known=1

    # Pre-compute each copy's version (one plutil spawn per copy) so the
    # no-install branch below can rank the copies before printing a verdict.
    copy_vers=()
    top_idx=-1
    top_ver=-1
    i=0
    for path in "${app_copies[@]}"; do
        ver=$(bundle_version "$path")
        copy_vers+=("${ver:-unknown}")
        if is_numeric "$ver" && [ "$ver" -gt "$top_ver" ]; then
            top_ver=$ver
            top_idx=$i
        fi
        i=$((i + 1))
    done

    if [ "$blessed_known" -eq 1 ]; then
        ghost_count=0
        i=0
        for path in "${app_copies[@]}"; do
            ver=${copy_vers[$i]}
            i=$((i + 1))
            sign=$(signing_summary "$path")
            if [ "$path" = "$blessed_path" ]; then
                add_item "$path" "$(basename "$path")" "version $ver, $sign (installed copy)" 'ok'
                continue
            fi

            # Strictly greater, not >=: an equal CFBundleVersion is most
            # likely a duplicate of the installed build (e.g. a Trashed copy
            # of the same release), and this script has no verified basis for
            # a tie-break — only a build that would actually outrank
            # /Applications is a ghost.
            if is_numeric "$ver" && [ "$ver" -gt "$blessed_version" ]; then
                add_item "$path" "$(basename "$path")" "version $ver, $sign — outranks the installed copy, wins the election" 'ghost'
                competing_copies+=("$path")
                ghost_count=$((ghost_count + 1))
            else
                add_item "$path" "$(basename "$path")" "version $ver, $sign" ''
            fi
        done
        if [ "$ghost_count" -gt 0 ]; then
            if [ "$ghost_count" -eq 1 ]; then
                copies_verdict='An on-disk copy outranks the installed /Applications build'
            else
                copies_verdict="$ghost_count on-disk copies outrank the installed /Applications build"
            fi
            copies_verdict_kind='ghost'
        else
            copies_verdict='No on-disk copy outranks the installed /Applications build'
            copies_verdict_kind='clean'
        fi
    elif [ "${#app_copies[@]}" -eq 1 ]; then
        copies_verdict='No /Applications install — the only on-disk copy wins the election unopposed'
        copies_verdict_kind='clean'
        add_item "${app_copies[0]}" "$(basename "${app_copies[0]}")" \
            "version ${copy_vers[0]}, $(signing_summary "${app_copies[0]}")" ''
    else
        # Without an installed copy there is nothing to outrank, so none of
        # these is a ghost by this script's definition — but multiple copies
        # mean the highest CFBundleVersion silently wins name/UTI resolution,
        # which is worth a glance.
        copies_verdict="No /Applications install to rank against — ${#app_copies[@]} copies on disk, highest version wins"
        copies_verdict_kind='warn'
        i=0
        for path in "${app_copies[@]}"; do
            # Coloured because this branch has no ✓/✗ marker to carry the
            # signal — every copy here is legitimate, and the only thing worth
            # spotting is which one the system actually resolves to. The ghost
            # branch above leaves its text plain, since its ✗ already says it.
            mark=''
            [ "$i" = "$top_idx" ] && mark=" ${c_yellow}← wins the election${c_reset}"
            add_item "$path" "$(basename "$path")" \
                "version ${copy_vers[$i]}, $(signing_summary "$path")$mark" ''
            i=$((i + 1))
        done
    fi
fi

# ---- verdicts, then one block per location ------------------------------------

case "$copies_verdict_kind" in
    clean) pass "$copies_verdict" ;;
    warn)  warn "$copies_verdict" ;;
    ghost) ghost "$copies_verdict" ;;
esac
# Each competing copy is its own fixable finding (the --fix loop below trashes
# them one at a time), so the count has to match even though they share a single
# verdict line.
if [ "$copies_verdict_kind" = 'ghost' ]; then
    found_count=$((found_count + ghost_count - 1))
fi

for (( li = 0; li < ${#loc_paths[@]}; li++ )); do
    # Column width is per block: one arena's bundle names are similar lengths,
    # and padding every block to a global maximum would reintroduce the ragged
    # whitespace this layout exists to remove.
    width=0
    for (( j = 0; j < ${#item_name[@]}; j++ )); do
        [ "${item_loc[$j]}" = "$li" ] || continue
        [ "${#item_name[$j]}" -gt "$width" ] && width=${#item_name[$j]}
    done

    # Plain, not bold: bold is the section-header weight, and a long hashed path
    # set at the same weight one level down flattens the hierarchy — it became
    # the loudest thing on screen while saying the least. The blank line and
    # indent delimit the block; the cyan worktree line below anchors it.
    printf '\n'
    printf '    %s\n' "$(pretty_path "${loc_paths[$li]}")"
    # Cyan, not dim: the worktree name is the line a reader scans a block for —
    # the hashed path above it is reference detail they already know how to
    # ignore. Dimming the identifier buried the one thing this whole feature
    # exists to surface.
    loc_label=$("$REPO_ROOT/Tools/arena-label.sh" "${loc_paths[$li]}" 2>/dev/null) || loc_label=''
    [ -n "$loc_label" ] && printf '    %s%s%s\n' "$c_cyan" "$loc_label" "$c_reset"

    for (( j = 0; j < ${#item_name[@]}; j++ )); do
        [ "${item_loc[$j]}" = "$li" ] || continue
        # Braced expansions: the marker glyphs are multi-byte, and bash reads
        # the leading bytes of a bare `$c_green✓` as part of the variable name,
        # which fails under `set -u` on the first marked item.
        case "${item_mark[$j]}" in
            ghost) marker="${c_red}✗${c_reset} " ;;
            ok)    marker="${c_green}✓${c_reset} " ;;
            *)     marker='  ' ;;
        esac
        # Meta prints in the default foreground: versions, team ids and the
        # election verdict are the payload of this section, and the aligned
        # column already separates them from the name without needing a colour.
        printf '      %s%-*s  %s\n' \
            "$marker" "$width" "${item_name[$j]}" "${item_meta[$j]}"
    done
done

if [ "$FIX" = 1 ] && [ "${#competing_copies[@]}" -gt 0 ]; then
    printf '\n'
    if [ ! -t 0 ]; then
        detail 'Not evicting competing copies: stdin is not a TTY, run interactively to confirm.'
    elif ! command -v trash >/dev/null 2>&1; then
        detail 'Not evicting competing copies: the `trash` CLI is not installed (brew install trash).'
    else
        for path in "${competing_copies[@]}"; do
            printf '  Trash and unregister %s? [y/N] ' "$path"
            # Default to empty (falls through to the skip branch below)
            # rather than leaving $reply unset: under `set -u`, EOF on
            # `read` (e.g. Ctrl-D at the prompt) never assigns it, and
            # referencing an unset var would abort the whole script.
            reply=''
            read -r reply || true
            case "$reply" in
                y|Y|yes|YES)
                    if trash "$path" 2>/dev/null; then
                        "$LSREGISTER" -u "$path" >/dev/null 2>&1
                        # Same best-effort-then-verify discipline as the
                        # Launch Services ghost fix above: don't trust
                        # the unregister exit code, re-check the dump.
                        if printf '%s\n' "$(kernova_registered_paths)" | grep -qxF "$path"; then
                            detail "trashed but still registered: $path (re-run to retry unregistering)"
                        else
                            fixed "trashed and unregistered: $path"
                        fi
                    else
                        detail "trash failed for $path"
                    fi
                    ;;
                *)
                    detail "skipped: $path"
                    ;;
            esac
        done
    fi
fi

# launchd's record is read-only diagnosis here, never a repair target: BTM
# does not self-clean, and its cross-path semantics on a scripted
# unregister/register are undocumented. Repair goes through a normal launch of
# the intended copy (which re-registers it), not a scripted fix in this script
# (#454).
launchd_line=$(launchctl print "gui/$(id -u)/app.kernova" 2>/dev/null | awk -F'= ' '/path = /{print $2; exit}')
if [ -n "$launchd_line" ]; then
    detail "launchd holds (read-only): $launchd_line"
fi

# ---- summary ------------------------------------------------------------------

section 'Summary'

if [ "$found_count" -eq 0 ]; then
    printf '%sNothing to clean up.%s\n' "$c_green" "$c_reset"
    exit 0
fi

# Findings are this script's output, not a failure, so the report-mode arm
# below exits 0 — `make ghosts` would otherwise stamp "Error 1" over its own
# closing instruction. A non-zero exit is reserved for not doing the requested
# job: `--fix` repairing less than it found, and the --evict failures above.
if [ "$FIX" = 1 ]; then
    printf '%d issue(s) found, %d fixed.\n' "$found_count" "$fixed_count"
    [ "$fixed_count" -lt "$found_count" ] && exit 1
    exit 0
else
    # `make` first, direct invocation second: this script is normally reached
    # through the Makefile, and `make ghosts --fix` does not do what leading
    # with the bare flag suggests — make swallows `--fix` as one of its own
    # options and bails with "unrecognized option".
    printf '%s%d issue(s) found.%s Run %smake clean-ghosts%s (or `Tools/ghosts.sh --fix`) to clean them up.\n' \
        "$c_yellow" "$found_count" "$c_reset" "$c_bold" "$c_reset"
    exit 0
fi
