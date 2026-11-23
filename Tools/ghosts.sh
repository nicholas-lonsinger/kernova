#!/usr/bin/env bash
# Find (and optionally clean up) ghost Kernova registrations left behind by
# torn-down worktrees (Claude Code's session-end auto-removal of a clean
# worktree, a manual `git worktree remove`, dragging the worktree to Trash,
# etc.).
#
# The moment Xcode builds an app bundle into a worktree's DerivedData, Launch
# Services' filesystem scanner discovers and registers it — the guest agent
# included, since nothing about that bundle is "guest-only" at the bundle
# level. If the worktree directory is then removed, that registration is never
# unregistered and lingers pointing at a path that no longer resolves.
#
# Checks for:
#   - Launch Services registrations whose `path:` no longer exists on disk,
#     under the current app.kernova.* identifiers and the legacy
#     pre-#471-rename `com.kernova.app` one alike
#   - Kernova build arenas in Xcode's own DerivedData folder, where the Xcode
#     app builds (`make` builds in each checkout's DerivedData/): counted and
#     sized, and never removed here, since one may be a build in use.
#   - xcode-build-server caches under ~/Library/Caches/xcode-build-server
#     named for a checkout of this clone that no longer exists — each holds
#     that checkout's editor index, and nothing removes it with the checkout
#   - Running processes executing from a Kernova path that no longer exists
#     on disk (the file was deleted out from under a still-running process)
#   - `git worktree list` entries marked `prunable` (administrative metadata
#     for a worktree whose directory is already gone)
#   - Directories under the primary checkout's .claude/worktrees/ that git
#     does not register (Tools/lib/worktrees.sh classifies them): one with no
#     project file is debris — a write into a removed worktree's path
#     recreates the directory — and goes to the Trash; a worktree moved by
#     hand is registered again with `git worktree repair`, and nothing is
#     pruned while one stays unrepaired; a checkout whose git record is gone,
#     a copy of another worktree, and one naming no record of this clone are
#     reported and left alone
#   - Registered worktrees under .claude/worktrees/ that are abandoned: no
#     live Claude Code session or subagent holds their lock, no session runs
#     inside them, nothing is uncommitted, and their HEAD is already on
#     GitHub: its content on origin/main — PRs merge by squash, so a finished
#     branch never reads as merged by ancestry — or its commits, or their
#     patches, on an origin branch or a pull request's head
#     (Tools/lib/worktrees.sh has the criteria); one a process still uses is
#     reported with its holders and never removed
#   - `worktree-*` branches — the ones Claude Code creates for its worktrees —
#     that no registered worktree has checked out, once their tip is on GitHub
#     by the same criteria
#   - LIVE on-disk Kernova.app copies (Trash, DerivedData) whose
#     CFBundleVersion outranks the installed /Applications copy — unlike the
#     dead-path ghosts above, Launch Services elects these by highest
#     CFBundleVersion (= squash-aware git commit count, see
#     Tools/set-build-number.sh), so a ghost build can shadow the real app
#     indefinitely even though version ordering can never favor the installed
#     copy on its own (#454). Deregistration/eviction is the only lever — and
#     only for a copy no build writes to: a checkout's build, or one in
#     Xcode's DerivedData folder, is reported as the winner but never evicted,
#     since its next build recreates and re-registers it, so trashing costs a
#     rebuild and fixes nothing.
#
# Run via `make ghosts` (report only) or `make clean-ghosts` (also fixes).
# Direct invocation: Tools/ghosts.sh [--fix]. The build pipeline's own
# operations on the same debris are Tools/build-arenas.sh's.
set -uo pipefail

FIX=0
# No argument is the report mode, so '' is an arm rather than falling to *).
usage='Usage: Tools/ghosts.sh [--fix]'
case "${1:-}" in
    '') ;;
    --fix) FIX=1 ;;
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

# shellcheck source=lib/output.sh
. "$REPO_ROOT/Tools/lib/output.sh"
# shellcheck source=lib/worktrees.sh
. "$REPO_ROOT/Tools/lib/worktrees.sh"
# shellcheck source=lib/build-arenas.sh
. "$REPO_ROOT/Tools/lib/build-arenas.sh"

XCODE_DD_ROOT=$(xcode_derived_data_root)

# xcode-build-server's per-checkout caches; Tools/lib/worktrees.sh
# (stale_build_server_caches) says which ones outlived their checkout.
BUILD_SERVER_CACHE="$HOME/Library/Caches/xcode-build-server"

# The process's own executable path. lsof's `txt` fd is the mapped binary,
# which is the only reliable source here: the arena holds bundles whose paths
# contain spaces ("Kernova Guest Agent.app"), so splitting `ps` args on
# whitespace would truncate them.
exe_of_pid() {
    lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# Out of place, recoverably: an abandoned worktree can still hold ignored files
# someone set by hand (a local .xcconfig, saved artifacts), so it goes to the
# Trash. Its DerivedData/ build arena is evicted first — a bundle in the Trash
# stays registered with Launch Services (see evict_arena).
# shellcheck disable=SC2329 # called through report_abandoned_worktrees
dispose_worktree() {
    if [ -d "$1/DerivedData" ] && [ ! -L "$1/DerivedData" ]; then
        evict_arena "$1/DerivedData"
    fi
    trash "$1" >/dev/null 2>&1
}

# ---- output helpers ----------------------------------------------------------

found_count=0
fixed_count=0

# section/pass/warn/value/detail/pretty_path/disk_size come from Tools/lib/output.sh.
# These two stay local because they also drive this script's summary counters.
ghost() { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; found_count=$((found_count + 1)); }
fixed() { printf '    %s→ fixed:%s %s\n' "$c_green" "$c_reset" "$1"; fixed_count=$((fixed_count + 1)); }

printf '%sKernova ghost cleanup%s\n' "$c_bold" "$c_reset"
# Names the mode, not the flag that selected it: the flag is unreachable through
# the Makefile front door anyway (make swallows `--fix` as one of its own
# options and bails), so echoing it back only suggests an argument the reader
# cannot actually pass to `make ghosts`.
[ "$FIX" = 1 ] && printf '%s(repair mode: will unregister, kill, prune, trash, remove, and evict)%s\n' "$c_dim" "$c_reset"

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
            lsregister -u "$path" >/dev/null 2>&1
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

# Before the prune: a moved worktree's record reads as prunable, and repairing
# it first is what keeps the prune from deleting it.
repair_failed=0
if read_worktree_layout "$REPO_ROOT"; then
    checkouts=$(unregistered_checkouts)
    while IFS=$'\t' read -r kind dir path; do
        [ -n "$kind" ] || continue
        case "$kind" in
            moved)
                ghost "Worktree moved by hand: $(pretty_path "$dir") — git lists it at $(pretty_path "$path")"
                if [ "$FIX" != 1 ]; then
                    detail "register it again: git worktree repair '$dir'"
                    continue
                fi
                # Re-read: once one copy of a record is repaired, any other
                # directory naming it is a copy of a live worktree.
                still=''
                read_worktree_layout "$REPO_ROOT" &&
                    still=$(DIR=$dir awk -F '\t' '$1 == "moved" && $2 == ENVIRON["DIR"]' <<<"$(unregistered_checkouts)")
                if [ -z "$still" ]; then
                    detail 'left alone: another directory naming its record was registered first'
                elif git -C "$REPO_ROOT" worktree repair "$dir" >/dev/null 2>&1 &&
                    read_worktree_layout "$REPO_ROOT" && worktree_registered "$dir"; then
                    fixed "registered again: $(pretty_path "$dir")"
                else
                    repair_failed=1
                    detail "git worktree repair '$dir' failed"
                fi
                ;;
            broken)
                warn "Checkout git cannot use: $(pretty_path "$dir") — the record its .git file names, $(pretty_path "$path"), is gone"
                detail 'its files are intact; nothing here removes it'
                ;;
            copy)
                warn "Copy of the worktree at $(pretty_path "$path"): $(pretty_path "$dir")"
                detail "its .git file names that worktree's record, so git commands in it act on that worktree's HEAD and index; nothing here changes it"
                ;;
            foreign)
                warn "Unregistered checkout that names no git record of this clone: $(pretty_path "$dir")"
                ;;
        esac
    done <<<"$checkouts"
fi

prunable=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep 'prunable' || true)
if [ -z "$prunable" ]; then
    pass 'No prunable git worktrees'
else
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ghost "Prunable worktree: $line"
    done <<< "$prunable"
    if [ "$FIX" = 1 ] && [ "$repair_failed" = 1 ]; then
        detail 'not pruned: a moved worktree above still depends on its record'
    elif [ "$FIX" = 1 ]; then
        if git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1; then
            fixed 'pruned stale worktree metadata'
        else
            detail 'git worktree prune failed'
        fi
    fi
fi

if read_worktree_layout "$REPO_ROOT"; then
    orphan_dirs=()
    while IFS= read -r dir; do
        orphan_dirs+=("$dir")
    done < <(orphaned_worktree_dirs)

    if [ "${#orphan_dirs[@]}" -eq 0 ]; then
        pass 'No orphaned directories under .claude/worktrees/'
    else
        for dir in "${orphan_dirs[@]}"; do
            ghost "Orphaned worktree directory: $(pretty_path "$dir") — $(disk_size "$dir")"
            if [ "$FIX" = 1 ]; then
                if trash "$dir" 2>/dev/null; then
                    fixed "trashed: $(pretty_path "$dir")"
                else
                    detail "trash failed for $(pretty_path "$dir")"
                fi
            fi
        done
    fi

    report_abandoned_worktrees "$REPO_ROOT" "$FIX" holder_blocked_lines dispose_worktree
    # After the worktree pass, so the branch of a worktree it removed goes too.
    report_orphaned_branches "$REPO_ROOT" "$FIX"
fi

# ---- Xcode's DerivedData folder ------------------------------------------------

section "Xcode's DerivedData folder"

xcode_arenas=()
while IFS= read -r dir; do
    xcode_arenas+=("$dir")
done < <(xcode_kernova_arenas)

# Information, not a finding: each is some checkout's build with Xcode's own
# location, the Xcode app's included, and nothing here says whose, or whether a
# build is writing it.
if [ "${#xcode_arenas[@]}" -eq 0 ]; then
    pass 'No Kernova build arenas'
else
    pass "${#xcode_arenas[@]} Kernova build arena(s), $(du -sch "${xcode_arenas[@]}" 2>/dev/null | awk 'END { print $1 }'): builds with Xcode's own location, the Xcode app's included"
fi

# ---- stale xcode-build-server caches -----------------------------------------

section 'xcode-build-server caches'

# Re-read: the abandoned-worktree pass above may have removed worktrees, whose
# caches are stale from that moment.
if ! read_worktree_layout "$REPO_ROOT"; then
    warn 'Skipped the xcode-build-server cache check: `git worktree list` could not be read'
else
    bsc_stale=()
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        bsc_stale+=("$dir")
    done < <(stale_build_server_caches "$BUILD_SERVER_CACHE")

    if [ "${#bsc_stale[@]}" -eq 0 ]; then
        pass 'No xcode-build-server caches left by removed checkouts'
    else
        refresh_holders "$BUILD_SERVER_CACHE"
        for dir in "${bsc_stale[@]}"; do
            ghost "Stale cache: $(pretty_path "$dir") — $(disk_size "$dir")"
            if path_held "$dir"; then
                while IFS= read -r blocked; do
                    detail "$blocked"
                done < <(holder_blocked_lines "$dir")
                continue
            fi
            if [ "$FIX" = 1 ]; then
                if evict_build_server_cache "$dir"; then
                    fixed "deleted: $(pretty_path "$dir")"
                else
                    detail "delete failed for $(pretty_path "$dir")"
                fi
            fi
        done
    fi
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
    local checkouts=$REPO_ROOT checkout
    read_worktree_layout "$REPO_ROOT" && checkouts=$worktree_paths
    {
        mdfind "kMDItemCFBundleIdentifier == 'app.kernova'" 2>/dev/null
        find "$HOME/.Trash" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        if [ -n "$XCODE_DD_ROOT" ]; then
            find "$XCODE_DD_ROOT" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        fi
        # Every checkout's DerivedData/, not just this one's: a sibling
        # worktree's copy competes as much as this checkout's.
        while IFS= read -r checkout; do
            [ -n "$checkout" ] || continue
            find "$checkout/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        done <<<"$checkouts"
    } | grep -v '/Index\.noindex/' | sort -u
}

# build_location <path> — whether <path> lies where a build writes: a
# registered checkout's DerivedData/, or Xcode's DerivedData folder.
build_location() {
    local checkout checkouts=$REPO_ROOT
    read_worktree_layout "$REPO_ROOT" && checkouts=$worktree_paths
    case "$1" in "$XCODE_DD_ROOT"/*) [ -n "$XCODE_DD_ROOT" ] && return 0 ;; esac
    while IFS= read -r checkout; do
        [ -n "$checkout" ] || continue
        case "$1" in "$checkout"/DerivedData/*) return 0 ;; esac
    done <<<"$checkouts"
    return 1
}

# Only registered copies enter the election, so only they are listed: a build
# unregistered after use (`make dead-code`'s) is on disk but cannot be picked,
# and shows up again the moment Launch Services re-registers it.
registered_now=$(kernova_registered_paths)
app_copies=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] || continue
    grep -qxF -- "$path" <<<"$registered_now" && app_copies+=("$path")
done < <(kernova_app_copies)

# Unlike the dead-path ghost check above, this reports the LIVE copies — the
# ones that still exist on disk but sit outside /Applications. Launch Services
# elects a handler by highest CFBundleVersion (a squash-aware git commit count
# — see Tools/set-build-number.sh), so a ghost build with a higher count can
# shadow the real app indefinitely; version ordering can never fix this on its
# own, eviction is the only lever (#454).
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

# add_item <path> <display-name> <meta> <mark>; mark is '', 'ok', 'live' or
# 'ghost'.
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
        live_count=0
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
                # A build a checkout or the Xcode app still writes to is the
                # ordinary state of a branch ahead of main, and eviction is
                # no lever against it: the next build recreates and
                # re-registers the copy. Report the shadowing, leave the
                # bundle; a removed worktree's builds went with it, so the
                # Trash holds the copies eviction can actually settle.
                if build_location "$path"; then
                    add_item "$path" "$(basename "$path")" "version $ver, $sign — outranks the installed copy, wins the election; a build location, not evicted" 'live'
                    live_count=$((live_count + 1))
                else
                    add_item "$path" "$(basename "$path")" "version $ver, $sign — outranks the installed copy, wins the election" 'ghost'
                    competing_copies+=("$path")
                    ghost_count=$((ghost_count + 1))
                fi
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
        elif [ "$live_count" -gt 0 ]; then
            if [ "$live_count" -eq 1 ]; then
                copies_verdict="A live checkout's build outranks the installed /Applications build (not evicted: its next build recreates it)"
            else
                copies_verdict="$live_count live checkouts' builds outrank the installed /Applications build (not evicted: their next build recreates them)"
            fi
            copies_verdict_kind='warn'
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

    # Plain, not bold: bold is the section-header weight, and a long path set
    # at the same weight one level down flattens the hierarchy. The blank line
    # and indent delimit the block.
    printf '\n'
    printf '    %s\n' "$(pretty_path "${loc_paths[$li]}")"

    for (( j = 0; j < ${#item_name[@]}; j++ )); do
        [ "${item_loc[$j]}" = "$li" ] || continue
        # Braced expansions: the marker glyphs are multi-byte, and bash reads
        # the leading bytes of a bare `$c_green✓` as part of the variable name,
        # which fails under `set -u` on the first marked item.
        case "${item_mark[$j]}" in
            ghost) marker="${c_red}✗${c_reset} " ;;
            live)  marker="${c_yellow}⚠${c_reset} " ;;
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
                        lsregister -u "$path" >/dev/null 2>&1
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
# job: `--fix` repairing less than it found.
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
