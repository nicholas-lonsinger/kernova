#!/usr/bin/env bash
# Resolve the DerivedData build arena Xcode uses for a project — the folder a
# flag-less `xcodebuild` and the Xcode GUI both build into (docs/BUILD.md
# "Derived data and build arenas").
#
# Usage:
#   Tools/derived-data-path.sh                                # this repo's Kernova.xcodeproj
#   Tools/derived-data-path.sh <path-to-.xcodeproj>           # any project path
#
# Prints the absolute arena directory (e.g. ~/Library/Developer/Xcode/
# DerivedData/Kernova-<hash>, or <project-dir>/DerivedData/Kernova in Relative
# mode). The project path does NOT need to exist: for Xcode's default
# (per-path-hashed ~/Library location) the folder name is a pure function of
# the absolute path string, which is what lets cleanup tooling locate a
# torn-down worktree's arena after the worktree itself is gone
# (Tools/ghosts.sh, `make clean`).
#
# Modes resolved, mirroring Xcode's Settings > Locations > Derived Data:
#   default   IDECustomDerivedDataLocation unset
#             -> ~/Library/Developer/Xcode/DerivedData/<Name>-<hash>
#   relative  the preference is a relative path (canonically "DerivedData")
#             -> <project-dir>/<pref>/<Name>    (nested per project, no hash)
#   custom    the preference is an absolute path
#             -> <pref>/<Name>-<hash>
#
# A per-user workspace override (Xcode's File > Project Settings…, stored in
# the workspace's xcuserdata) takes precedence over the global preference.
# Its on-disk semantics aren't documented, so rather than guess, this script
# defers to `xcodebuild -showBuildSettings` (authoritative, but needs the
# project to exist and costs a few seconds) only in that rare case.
#
# The hash: MD5 the project path's UTF-8 bytes, split the 16-byte digest into
# two big-endian 64-bit halves, and write each half as 14 base-26 letters
# ('a'..'z'), most significant digit first — 28 letters total. Verified
# against every live DerivedData folder's recorded WorkspacePath (info.plist).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${1:-$REPO_ROOT/Kernova.xcodeproj}"

# Absolutize without requiring existence (dirname may be gone for a
# torn-down worktree) — a relative argument is anchored at $PWD.
case "$project" in
    /*) ;;
    *) project="$PWD/$project" ;;
esac
project="${project%/}"

name="$(basename "$project")"
name="${name%.*}"
project_dir="$(dirname "$project")"

# xcode_dd_hash <absolute-path> — the 28-letter folder suffix.
#
# The two 64-bit digest halves exceed shell arithmetic's signed range, so the
# base-26 conversion runs in awk as two-limb long division: each half is split
# into 32-bit words (exact in awk's doubles), and every digit step divides
# across the (hi, lo) pair. All intermediates stay below 2^53, so the double
# math is exact.
xcode_dd_hash() {
    local digest
    digest="$(printf '%s' "$1" | md5 -q)"
    awk -v w0="$((16#${digest:0:8}))" -v w1="$((16#${digest:8:8}))" \
        -v w2="$((16#${digest:16:8}))" -v w3="$((16#${digest:24:8}))" '
        function half(hi, lo,    i, t, d, out) {
            out = ""
            for (i = 0; i < 14; i++) {
                t = (hi % 26) * 4294967296 + lo
                d = t % 26
                lo = int(t / 26)
                hi = int(hi / 26)
                out = sprintf("%c", 97 + d) out
            }
            return out
        }
        BEGIN { printf "%s%s", half(w0, w1), half(w2, w3) }'
}

# Per-user workspace override: presence alone diverts resolution, matching the
# Makefile probe. `$USER` mirrors how Xcode names the xcuserdatad folder.
settings="$project/project.xcworkspace/xcuserdata/$USER.xcuserdatad/WorkspaceSettings.xcsettings"
if [ -f "$settings" ] \
    && plutil -extract DerivedDataCustomLocation raw "$settings" -o - >/dev/null 2>&1; then
    build_dir="$(xcodebuild -project "$project" -showBuildSettings 2>/dev/null \
        | sed -n 's/^ *BUILD_DIR = //p' | head -1)"
    if [ -z "$build_dir" ]; then
        echo "derived-data-path.sh: workspace has a per-user derived-data override but xcodebuild could not resolve it" >&2
        exit 1
    fi
    printf '%s\n' "${build_dir%/Build/Products}"
    exit 0
fi

global="$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)"
case "$global" in
    '')
        printf '%s/Library/Developer/Xcode/DerivedData/%s-%s\n' \
            "$HOME" "$name" "$(xcode_dd_hash "$project")"
        ;;
    /*)
        printf '%s/%s-%s\n' "${global%/}" "$name" "$(xcode_dd_hash "$project")"
        ;;
    *)
        printf '%s/%s/%s\n' "$project_dir" "${global%/}" "$name"
        ;;
esac
