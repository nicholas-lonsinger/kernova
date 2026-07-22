#!/usr/bin/env bash
# Find (and optionally clean up) ghost Kernova registrations left behind by
# torn-down worktrees (Claude Code's session-end auto-removal of a clean
# worktree, a manual `git worktree remove`, dragging the worktree to Trash,
# etc.).
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
#     dead-path ghosts above, LaunchServices/PluginKit elect these by highest
#     CFBundleVersion (= squash-aware git commit count, see docs/BUILD.md "Build
#     version"), so a ghost build can shadow the real app indefinitely even
#     though version ordering can never favor the installed copy on its own
#     (#454). Deregistration/eviction is the only lever.
#
# Run via `make ghosts` (report only) or `make clean-ghosts` (also fixes).
# Direct invocation: Tools/ghosts.sh [--fix | --sweep]
# (--sweep-ls is the former name of --sweep, kept as an alias for any
# installed hooks from before the arena sweep was added.)

set -uo pipefail

FIX=0
SWEEP=0
case "${1:-}" in
    --fix) FIX=1 ;;
    --sweep | --sweep-ls) SWEEP=1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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

# Xcode DerivedData arenas left by torn-down worktrees. On machines using
# Xcode's default derived-data location, every worktree the GUI opens gets a
# permanent per-path-hashed folder under ~/Library — nothing removes it when
# the worktree goes away, and the LS-registered app copy inside keeps
# competing in the CFBundleVersion election (docs/BUILD.md "Derived data and build arenas").
# Each folder records its source project in info.plist's WorkspacePath; that
# recorded path is the ground truth for orphan detection (and stays readable
# after the worktree is deleted). Tools/derived-data-path.sh computes the same
# worktree->arena mapping forward when a single arena needs locating.
XCODE_DD_ROOT="$HOME/Library/Developer/Xcode/DerivedData"

# The worktrees all live under the *primary* checkout's .claude/worktrees/,
# which REPO_ROOT is not when this script runs from inside a worktree — the
# first `git worktree list` entry is the primary checkout.
main_root=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')

# Print one arena directory per line whose recorded WorkspacePath sits in a
# .claude/worktrees/ worktree of this repo that no longer exists on disk.
# Scoped to this repo's worktrees deliberately: a deleted checkout of some
# other project is not this script's call to clean up.
orphaned_dd_arenas() {
    [ -n "$main_root" ] || return 0
    local info ws wt_dir
    for info in "$XCODE_DD_ROOT"/*/info.plist; do
        [ -f "$info" ] || continue
        ws=$(plutil -extract WorkspacePath raw "$info" -o - 2>/dev/null) || continue
        case "$ws" in
            "$main_root/.claude/worktrees/"*) ;;
            *) continue ;;
        esac
        wt_dir=${ws#"$main_root/.claude/worktrees/"}
        wt_dir="$main_root/.claude/worktrees/${wt_dir%%/*}"
        [ -d "$wt_dir" ] && continue
        printf '%s\n' "${info%/info.plist}"
    done
}

# PIDs of processes executing from inside the arena (e.g. a File Provider
# extension fileproviderd kept alive) — eviction would yank their binaries.
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

# True when something other than an on-demand app extension is running from
# the arena. An .appex is an XPC service its host daemon (fileproviderd, pkd)
# starts on demand and restarts on the next request, so terminating one costs
# at most an in-flight request. Anything else — the app itself, a test runner —
# may be mid-VM-session and is the user's to quit, so the arena is left alone.
arena_has_non_appex() {
    local pid exe
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        exe=$(exe_of_pid "$pid")
        # An unreadable exe path (the process exited between the ps and the
        # lsof) can't be classified as safe to kill — treat it as blocking.
        case "$exe" in
            *.appex/*) ;;
            *) return 0 ;;
        esac
    done < <(arena_pids "$1")
    return 1
}

# Terminate the extension processes running from the arena so it can be
# evicted. Callers must rule out non-appex processes first. Returns 0 only
# once the arena is actually free.
kill_arena_appexes() {
    local dir=$1 i
    local pids=()
    while IFS= read -r i; do
        [ -z "$i" ] && continue
        pids+=("$i")
    done < <(arena_pids "$dir")
    [ "${#pids[@]}" -eq 0 ] && return 0
    kill "${pids[@]}" 2>/dev/null
    # kill only requests termination; wait for the daemons to reap before
    # calling the arena free, and give up rather than block if one hangs.
    for i in 1 2 3 4 5 6 7 8 9 10; do
        arena_in_use "$dir" || return 0
        sleep 0.2
    done
    return 1
}

# Unregister every bundle inside the arena, then trash the folder. Unregister
# first: a copy trashed while still registered keeps competing in the
# election (#454) — the order matters.
evict_dd_arena() {
    local dir=$1 app
    while IFS= read -r app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1
    done < <(find "$dir" -maxdepth 6 -name '*.app' -type d 2>/dev/null)
    command -v trash >/dev/null 2>&1 || return 1
    trash "$dir" 2>/dev/null
}

# --sweep: the quiet, non-interactive subset for hooks — unregister dead
# app.kernova.* Launch Services registrations, evict DerivedData arenas
# orphaned by torn-down worktrees, and exit. The post-checkout git hook runs
# it on every new worktree, so debris left by torn-down worktrees self-heals
# at the next worktree creation. Best-effort by design: always exits 0 so a
# failed sweep can never fail the checkout that triggered it, skips anything
# a process is still running from, and skips the fix path's re-dump
# verification — `make ghosts` still reports anything left behind. Unlike
# --fix it never terminates the extension blocking an arena: the sweep runs
# unattended from a git hook, and the next worktree creation sweeps again.
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
            printf 'ghosts.sh: evicted orphaned worktree DerivedData arena: %s\n' "$dir"
        fi
    done < <(orphaned_dd_arenas)
    exit 0
fi

# ---- output helpers (matches Tools/doctor.sh) --------------------------------

if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yellow=$'\033[0;33m'
    c_dim=$'\033[0;90m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_yellow=''; c_dim=''; c_bold=''; c_reset=''
fi

found_count=0
fixed_count=0
# Subset of found_count that `--fix` deliberately does not repair, so the
# summary can point at the manual step instead of promising `make clean-ghosts`
# will clear it.
manual_count=0

clean()   { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()    { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$1"; }
ghost()   { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; found_count=$((found_count + 1)); }
fixed()   { printf '    %s→ fixed:%s %s\n' "$c_green" "$c_reset" "$1"; fixed_count=$((fixed_count + 1)); }
detail()  { printf '    %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
section() { printf '\n%s%s%s\n' "$c_bold" "$1" "$c_reset"; }

# Display-only: abbreviate $HOME to ~ so deep DerivedData paths stay scannable.
pretty_path() { printf '%s' "${1/#$HOME/~}"; }

printf '%sKernova ghost cleanup%s\n' "$c_bold" "$c_reset"
[ "$FIX" = 1 ] && printf '%s(--fix: will unregister, kill, and prune)%s\n' "$c_dim" "$c_reset"

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
                detail 'Unexpected — a plain `lsregister -u` normally sticks even once the path is gone (see Tools/ls-reset.sh). Re-run this script; if it persists, file a bug rather than reaching for `lsregister -kill` (removed on current macOS).'
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
# An arena an on-demand extension is running from is unblocked by terminating
# it (fileproviderd/pkd restart the .appex on the next request); an arena the
# app itself is running from is skipped with a pointer instead, since quitting
# a possibly-in-use app is not this script's call.
dd_orphans=()
while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    dd_orphans+=("$dir")
done < <(orphaned_dd_arenas)

if [ "${#dd_orphans[@]}" -eq 0 ]; then
    clean 'No DerivedData arenas left by torn-down worktrees'
else
    for dir in "${dd_orphans[@]}"; do
        ghost "Orphaned worktree arena: $(pretty_path "$dir") ($(du -sh "$dir" 2>/dev/null | cut -f1))"
        if arena_in_use "$dir"; then
            if arena_has_non_appex "$dir"; then
                detail 'a running app is still executing from inside — quit it (or reboot), then re-run'
                continue
            elif [ "$FIX" != 1 ]; then
                detail 'an on-demand extension is running from inside — `make clean-ghosts` terminates it'
                continue
            elif ! kill_arena_appexes "$dir"; then
                detail 'the extension(s) running from inside would not exit — reboot, then re-run'
                continue
            fi
            detail 'terminated the on-demand extension(s) running from inside'
        fi
        if [ "$FIX" = 1 ]; then
            if evict_dd_arena "$dir"; then
                fixed "unregistered bundles and trashed: $(pretty_path "$dir")"
            elif ! command -v trash >/dev/null 2>&1; then
                detail 'not evicted: the `trash` CLI is unavailable'
            else
                detail "trash failed for $dir"
            fi
        fi
    done
fi

# ---- on-disk Kernova.app copies ----------------------------------------------

# Enumerated here, ahead of the section that reports them, because the File
# Provider verdict below turns on whether any Kernova build exists on disk at
# all: a domain whose extension "was not found" is the expected resting state
# when nothing is built, and a genuine wedge when a build is sitting right
# there. Trash and DerivedData are walked explicitly because both escape
# `mdfind` — DerivedData ships a `.metadata_never_index` sentinel and Trash is
# excluded from Spotlight entirely.
kernova_app_copies() {
    {
        mdfind "kMDItemCFBundleIdentifier == 'app.kernova'" 2>/dev/null
        find "$HOME/.Trash" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        find "$REPO_ROOT/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
    } | sort -u
}

app_copies=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && app_copies+=("$path")
done < <(kernova_app_copies)

# ---- stale File Provider domains ---------------------------------------------

section 'File Provider domains'

# fileproviderd binds each registered domain to its extension by bundle id and
# caches the launch path. A rebuild that moves or deletes the extension binary —
# or a competing copy at a different DerivedData path — can wedge the binding
# (Copy to Mac then beeps, because the extension can't launch), and a torn-down
# extension can strand a dead-end domain. macOS 26's fileproviderctl can only
# `dump`, not remove, so this only REPORTS; clear it with `make fp-reset`, which
# restarts fileproviderd — the app re-registers a fresh domain on next launch.
#
# The dump interleaves every provider on the machine, so read the flags out of
# Kernova's own `===== / <bundle id> / =====` block: a bare `grep DeadEndBackend`
# over the whole dump reports iCloud Drive's or Photos' wedged domain as
# Kernova's. Two flags matter and they mean different things — `extension not
# found` is fileproviderd saying it cannot locate the extension bundle at all,
# whereas a dead-end backend with the extension present is a binding that went
# bad. Escape sequences are stripped first because fileproviderctl colors its
# output unconditionally, even into a pipe.
fp_dump=$(fileproviderctl dump 2>/dev/null || true)
fp_flags=$(printf '%s\n' "$fp_dump" | awk '
    {
        line = $0
        gsub(/\033\[[0-9;]*m/, "", line)
        if (line ~ /^=+$/ && prev2 ~ /^=+$/ && prev1 ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
            kern = (prev1 ~ /^app\.kernova(\.|$)/)
            if (kern) registered = 1
        } else if (kern) {
            if (line ~ /extension not found/) notfound = 1
            if (line ~ /DeadEndBackend/) deadend = 1
        }
        prev2 = prev1
        prev1 = line
    }
    END {
        if (registered) print "registered"
        if (notfound) print "notfound"
        if (deadend) print "deadend"
    }
')
fp_has() { printf '%s\n' "$fp_flags" | grep -qx "$1"; }

if ! printf '%s\n' "$fp_dump" | grep -qiE "app\.kernova|kernova-clipboard"; then
    clean 'No Kernova File Provider domains registered'
elif fp_has notfound; then
    # A domain outlives the build that registered it — that is the system
    # working as designed, not debris: the registration is what lets the next
    # launch adopt the domain instead of minting a second one. So this is a
    # ⚠ note, not a counted ✗ — there is nothing here for `--fix` to repair,
    # and `make fp-reset` cannot conjure an extension binary that isn't on disk.
    if [ "${#app_copies[@]}" -eq 0 ]; then
        warn 'A Kernova File Provider domain is registered with no build on disk to serve it'
        detail 'fileproviderd reports "extension not found" — expected after `make clean`, a torn-down'
        detail 'worktree, or on a machine with no Kernova installed. The domain is inert until a build'
        detail 'exists; building and launching Kernova re-binds it. Nothing to clean up.'
    else
        warn "A Kernova File Provider domain has no extension to bind to, though ${#app_copies[@]} build(s) are on disk"
        detail 'fileproviderd reports "extension not found" — normal if no copy is running or the domain was'
        detail 'registered by a build since deleted. Launch Kernova to re-bind; if Copy to Mac still beeps'
        detail 'afterwards, `make fp-reset` clears the stale binding.'
    fi
elif fp_has deadend; then
    ghost 'A Kernova File Provider domain looks wedged (dead-end backend) with its extension present'
    detail 'Run `make fp-reset`, then relaunch Kernova to re-register a fresh domain.'
    detail '(`make clean-ghosts` deliberately leaves this alone — restarting fileproviderd briefly'
    detail 'interrupts every File Provider on the machine, so it stays an opt-in step.)'
    detail 'A stale "Kernova Clipboard (Mac)" Finder location that survives fp-reset needs a full domain'
    detail 'removal instead: run any build of Kernova with `--remove-clipboard-domain` (#454, #467, #516).'
    detail 'This resets the domain'"'"'s System Settings enablement, so use it only when fp-reset didn'"'"'t help.'
    manual_count=$((manual_count + 1))
else
    clean 'Kernova File Provider domain(s) registered, none dead-ended'
    detail 'If Copy to Mac beeps or hangs, `make fp-reset` clears stale fileproviderd bindings.'
fi

# ---- live on-disk copies & Launch Services/PluginKit election ----------------

section 'On-disk copies & registration election'

# Unlike the dead-path ghost check above, this reports the LIVE copies
# enumerated before the File Provider section — the ones that still exist on
# disk but sit outside /Applications. LaunchServices/PluginKit elect a handler
# by highest CFBundleVersion (a squash-aware git commit count — see
# docs/BUILD.md "Build version"), so a ghost build with a higher count can shadow
# the real app indefinitely; version ordering can never fix this on its own,
# eviction is the only lever (#454).
bundle_version() {
    plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

# Ad-hoc vs. a real identity — mixed signing across copies breaks the
# app-group/relay handshake and masquerades as an unrelated bug.
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

if [ "${#app_copies[@]}" -eq 0 ]; then
    clean 'No on-disk Kernova.app copies found'
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

    competing_copies=()
    if [ "$blessed_known" -eq 1 ]; then
        i=0
        for path in "${app_copies[@]}"; do
            ver=${copy_vers[$i]}
            i=$((i + 1))
            sign=$(signing_summary "$path")
            if [ "$path" = "$blessed_path" ]; then
                clean "$path — version $ver, $sign (installed copy)"
                continue
            fi

            # Strictly greater, not >=: an equal CFBundleVersion is most
            # likely a duplicate of the installed build (e.g. a Trashed copy
            # of the same release), and this script has no verified basis for
            # a tie-break — only a build that would actually outrank
            # /Applications is a ghost.
            outranks=0
            if is_numeric "$ver" && [ "$ver" -gt "$blessed_version" ]; then
                outranks=1
            fi
            if [ "$outranks" = 1 ]; then
                ghost "$(pretty_path "$path") — version $ver, $sign (outranks the installed copy, wins the election)"
                competing_copies+=("$path")
            else
                detail "$(pretty_path "$path") — version $ver, $sign"
            fi
        done
    elif [ "${#app_copies[@]}" -eq 1 ]; then
        clean 'No /Applications install — the only on-disk copy wins the election unopposed:'
        detail "$(pretty_path "${app_copies[0]}") — version ${copy_vers[0]}, $(signing_summary "${app_copies[0]}")"
    else
        # Without an installed copy there is nothing to outrank, so none of
        # these is a ghost by this script's definition — but multiple copies
        # mean the highest CFBundleVersion silently wins name/UTI resolution,
        # which is worth a glance.
        warn "No /Applications install to rank against — ${#app_copies[@]} copies on disk, highest version wins:"
        i=0
        for path in "${app_copies[@]}"; do
            mark=''
            [ "$i" = "$top_idx" ] && mark=' ← wins the election'
            detail "$(pretty_path "$path") — version ${copy_vers[$i]}, $(signing_summary "$path")$mark"
            i=$((i + 1))
        done
    fi

    if [ "$FIX" = 1 ] && [ "${#competing_copies[@]}" -gt 0 ]; then
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
fi

# PlugInKit's election for the two appexes follows the same highest-version
# rule as the app itself. Report-only — recovering a wedged plugin means
# evicting the competing app copy above, not a targeted pluginkit repair.
# A default `pluginkit -m` returns only the election winner. Each match line
# is "<election-marker> id(version)<TAB>uuid<TAB>registered<TAB>path",
# followed by a tab-less "(N plug-ins)" count line — keep the version and
# winning path, drop the UUID/timestamp/count noise. Collect everything
# first so the verdict line can lead and the per-appex lines sit under it.
pk_lines=()
pk_dead=()
pk_registered=0
for id in app.kernova.fileprovider app.kernova.macosagent.fileprovider; do
    info=$(pluginkit -m -v -i "$id" 2>/dev/null)
    # Count the match lines actually parsed rather than testing $info for
    # emptiness: an unregistered id makes pluginkit print "  (no matches)",
    # not nothing, so an emptiness test would report every id as registered
    # and then print the verdict header with no bundles under it.
    id_matches=0
    while IFS=$'\t' read -r head _uuid _registered path; do
        [ -z "$path" ] && continue
        ver=${head##*\(}
        ver=${ver%\)}
        # The election marker only matters when it says the winner is not
        # actually in use (man pluginkit); `+`/blank are the normal states.
        note=''
        case "$head" in
            '-'*) note=' (user elected to ignore)' ;;
            '='*) note=' (superseded by another plug-in)' ;;
        esac
        [ -e "$path" ] || pk_dead+=("$id")
        pk_lines+=("$id $ver — $(pretty_path "$path")$note")
        id_matches=$((id_matches + 1))
    done <<< "$info"
    if [ "$id_matches" -eq 0 ]; then
        pk_lines+=("$id — not registered with PlugInKit")
    else
        pk_registered=$((pk_registered + 1))
    fi
done

if [ "${#pk_dead[@]}" -gt 0 ]; then
    # Not counted as a fixable issue: pluginkit offers no scripted repair —
    # pkd re-elects on its next discovery pass (e.g. relaunching the intended
    # copy, or evicting the competing copy above).
    warn "PlugInKit election(s) point at deleted paths: ${pk_dead[*]}"
elif [ "$pk_registered" -eq 0 ]; then
    clean 'No app.kernova.* appexes registered with PlugInKit'
    pk_lines=()
else
    clean 'PlugInKit appex elections point at bundles present on disk:'
fi
if [ "${#pk_lines[@]}" -gt 0 ]; then
    for line in "${pk_lines[@]}"; do
        detail "$line"
    done
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

if [ "$FIX" = 1 ]; then
    printf '%d issue(s) found, %d fixed.\n' "$found_count" "$fixed_count"
    [ "$manual_count" -gt 0 ] && printf '%d need the manual step noted above; --fix does not perform it.\n' "$manual_count"
    [ "$fixed_count" -lt "$found_count" ] && exit 1
    exit 0
elif [ "$manual_count" -eq "$found_count" ]; then
    printf '%s%d issue(s) found.%s Follow the step(s) noted above — %smake clean-ghosts%s does not repair these.\n' \
        "$c_yellow" "$found_count" "$c_reset" "$c_bold" "$c_reset"
    exit 1
else
    # `make` first, direct invocation second: this script is normally reached
    # through the Makefile, and `make ghosts --fix` does not do what leading
    # with the bare flag suggests — make swallows `--fix` as one of its own
    # options and bails with "unrecognized option".
    printf '%s%d issue(s) found.%s Run %smake clean-ghosts%s (or `Tools/ghosts.sh --fix`) to clean them up.\n' \
        "$c_yellow" "$found_count" "$c_reset" "$c_bold" "$c_reset"
    exit 1
fi
