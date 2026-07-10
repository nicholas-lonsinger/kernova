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
#   - LIVE on-disk Kernova.app copies (Trash, DerivedData) whose
#     CFBundleVersion outranks the installed /Applications copy — unlike the
#     dead-path ghosts above, LaunchServices/PluginKit elect these by highest
#     CFBundleVersion (= squash-aware git commit count, see CLAUDE.md "Build
#     version"), so a ghost build can shadow the real app indefinitely even
#     though version ordering can never favor the installed copy on its own
#     (#454). Deregistration/eviction is the only lever.
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
        if git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1; then
            fixed 'pruned stale worktree metadata'
        else
            detail 'git worktree prune failed'
        fi
    fi
fi

# ---- stale File Provider domains ---------------------------------------------

section 'File Provider domains'

# fileproviderd binds each registered domain to its extension by bundle id and
# caches the launch path. A rebuild that moves or deletes the extension binary —
# or a competing copy at a different DerivedData path — can wedge the binding
# (Copy to Mac then beeps, because the extension can't launch), and a torn-down
# extension can strand a dead-end domain. macOS 26's fileproviderctl can only
# `dump`, not remove, so this only REPORTS; clear it with `make fp-reset`, which
# restarts fileproviderd — the app re-registers a fresh domain on next launch.
# The dead-end check isn't domain-scoped (the dump groups backends per-domain
# but is awkward to parse), so on a machine with other providers it can
# over-report; running fp-reset is harmless either way.
fp_dump=$(fileproviderctl dump 2>/dev/null || true)
if ! printf '%s\n' "$fp_dump" | grep -qiE "app\.kernova|kernova-clipboard"; then
    clean 'No Kernova File Provider domains registered'
elif printf '%s\n' "$fp_dump" | grep -q "DeadEndBackend"; then
    ghost 'A File Provider domain looks wedged (dead-end backend) with Kernova registered'
    detail 'Run `make fp-reset`, then relaunch Kernova to re-register a fresh domain.'
    detail 'A stale "Kernova Clipboard (Mac)" Finder location that survives fp-reset needs a full domain'
    detail 'removal instead: run any build of Kernova with `--remove-clipboard-domain` (#454, #467, #516).'
    detail 'This resets the domain'"'"'s System Settings enablement, so use it only when fp-reset didn'"'"'t help.'
else
    clean 'Kernova File Provider domain(s) registered, none dead-ended'
    detail 'If Copy to Mac beeps or hangs, `make fp-reset` clears stale fileproviderd bindings.'
fi

# ---- live on-disk copies & Launch Services/PluginKit election ----------------

section 'On-disk copies & registration election'

# Unlike the dead-path ghost check above, this looks for LIVE copies that
# still exist on disk but sit outside /Applications — Trash and DerivedData
# are the two sources that actually outrank an installed copy, because both
# escape `mdfind`: DerivedData ships a `.metadata_never_index` sentinel and
# Trash is excluded from Spotlight entirely. LaunchServices/PluginKit elect a
# handler by highest CFBundleVersion (a squash-aware git commit count — see
# CLAUDE.md "Build version"), so a ghost build with a higher count can shadow
# the real app indefinitely; version ordering can never fix this on its own,
# eviction is the only lever (#454).
kernova_app_copies() {
    {
        mdfind "kMDItemCFBundleIdentifier == 'app.kernova'" 2>/dev/null
        find "$HOME/.Trash" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
        find "$REPO_ROOT/DerivedData" -maxdepth 6 -iname 'Kernova.app' -type d 2>/dev/null
    } | sort -u
}

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

app_copies=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && app_copies+=("$path")
done < <(kernova_app_copies)

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

# PlugInKit's election for the three appexes follows the same highest-version
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
for id in app.kernova.quicklook app.kernova.fileprovider app.kernova.macosagent.fileprovider; do
    info=$(pluginkit -m -v -i "$id" 2>/dev/null)
    if [ -z "$info" ]; then
        pk_lines+=("$id — not registered with PlugInKit")
        continue
    fi
    pk_registered=$((pk_registered + 1))
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
    done <<< "$info"
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
    [ "$fixed_count" -lt "$found_count" ] && exit 1
    exit 0
else
    printf '%s%d issue(s) found.%s Re-run with %s--fix%s (or `make clean-ghosts`) to clean them up.\n' \
        "$c_yellow" "$found_count" "$c_reset" "$c_bold" "$c_reset"
    exit 1
fi
