#!/usr/bin/env bash
# Unregisters Kernova Launch Services entries under the legacy pre-#471-rename
# `com.kernova.app` identifier whose `path:` no longer exists on disk.
#
# Tools/ghosts.sh's Launch Services check only pattern-matches the CURRENT
# `app.kernova` identifier, so it can't see (or fix) registrations left over
# from before the #471 naming-cleanup rename. This script covers exactly that
# gap for now — TODO: fold into Tools/ghosts.sh once the legacy-identifier
# era is retired (broaden its regex to match both, delete this script).
#
# The originally planned fix was a system-wide `lsregister -kill -r` rebuild,
# but `-kill` has been removed from lsregister on current macOS ("dangerous
# and no longer useful" per `lsregister -h`) — and turns out to be
# unnecessary anyway: plain `lsregister -u <path>` reliably unregisters an
# entry even once its path is fully gone (verified empirically 2026-07-08),
# contradicting ghosts.sh's own comment that it wouldn't stick.
#
# Run via `make ls-reset`. Direct invocation: Tools/ls-reset.sh

set -uo pipefail

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# ---- output helpers (matches Tools/ghosts.sh / Tools/doctor.sh) --------------

if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'
    c_dim=$'\033[0;90m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_dim=''; c_bold=''; c_reset=''
fi

found_count=0
fixed_count=0

ghost()  { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; found_count=$((found_count + 1)); }
fixed()  { printf '    %s→ fixed:%s %s\n' "$c_green" "$c_reset" "$1"; fixed_count=$((fixed_count + 1)); }
detail() { printf '    %s%s%s\n' "$c_dim" "$1" "$c_reset"; }

printf '%sKernova legacy Launch Services reset (com.kernova.app)%s\n' "$c_bold" "$c_reset"

# lsregister's dump lists `path:` a few lines before the `identifier:` line
# for the same entry, with entries separated by a full-width dash rule —
# track the most recently seen path and reset it at each rule so an
# identifier never gets paired with a path from a different entry.
legacy_registered_paths() {
    "$LSREGISTER" -dump 2>/dev/null | awk '
        /^-+$/ { path = "" }
        /^path:/ {
            line = $0
            sub(/^path:[ \t]*/, "", line)
            sub(/ \(0x[0-9a-fA-F]+\)[ \t]*$/, "", line)
            path = line
        }
        /^identifier:[ \t]+com\.kernova\.app$/ {
            if (path != "") print path
        }
    ' | sort -u
}

# Built via a plain read loop rather than `mapfile`/`readarray`: macOS ships
# bash 3.2 (GPLv3), which predates both builtins.
ghost_paths=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$path" ] && continue
    ghost_paths+=("$path")
done < <(legacy_registered_paths)

if [ "${#ghost_paths[@]}" -eq 0 ]; then
    printf '  %s✓%s No legacy com.kernova.app ghost registrations found\n' "$c_green" "$c_reset"
    exit 0
fi

for path in "${ghost_paths[@]}"; do
    ghost "Registered but missing on disk: $path"
done

for path in "${ghost_paths[@]}"; do
    "$LSREGISTER" -u "$path" >/dev/null 2>&1
done

still_registered=$(legacy_registered_paths)
for path in "${ghost_paths[@]}"; do
    if printf '%s\n' "$still_registered" | grep -qxF "$path"; then
        detail "still registered: $path"
    else
        fixed "unregistered: $path"
    fi
done

printf '\n%d issue(s) found, %d fixed.\n' "$found_count" "$fixed_count"
[ "$fixed_count" -lt "$found_count" ] && exit 1
exit 0
