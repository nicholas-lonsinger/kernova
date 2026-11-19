#!/usr/bin/env bash
# Fixture tests for Tools/arena-label.sh: which checkout an arena that records
# none matches by name, when a match to none reads as `unclaimed`, and when a
# worktree git does not list at its path still reads as live. Runs a copy of
# the scripts inside a fixture clone, with HOME in the fixture so the default
# arena root is too.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else fail "$1: got '$2', wanted '$3'"; fi
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

clone="$tmp/clone"
git init -q -b main "$clone" && git -C "$clone" commit -q --allow-empty -m init
mkdir -p "$clone/Tools/lib"
cp "$ROOT/Tools/arena-label.sh" "$ROOT/Tools/derived-data-path.sh" "$clone/Tools/"
cp "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/arena-records.sh" "$ROOT/Tools/lib/worktrees.sh" "$ROOT/Tools/lib/holders.sh" \
    "$ROOT/Tools/lib/xcodebuild-flags.sh" "$clone/Tools/lib/"
git -C "$clone" worktree add -q --detach "$clone/.claude/worktrees/live"

export HOME="$tmp/home"
dd_root=$("$clone/Tools/derived-data-path.sh" --root) || { echo "arena-label fixtures: derived-data-path.sh --root failed" >&2; exit 1; }
case "$dd_root" in
    "$tmp"/*) ;;
    *)
        printf '  ✓ arena-label: skipped — Xcode'\''s derived-data location is set outside HOME (%s)\n' "$dd_root"
        exit 0
        ;;
esac

# arena_for <checkout> <entry>... — the arena that checkout's project hashes
# to, holding the given top-level entries; prints its path.
arena_for() {
    local arena
    arena=$("$clone/Tools/derived-data-path.sh" "$1/Kernova.xcodeproj")
    shift
    mkdir -p "$arena"
    for entry in "$@"; do mkdir -p "$arena/$entry"; done
    printf '%s' "$arena"
}
status_of() { "$clone/Tools/arena-label.sh" --status "$1" 2>/dev/null || printf 'unattributable'; }

check "main, packages only" "$(status_of "$(arena_for "$clone" SourcePackages Logs)")" main
check "live worktree, packages only" \
    "$(status_of "$(arena_for "$clone/.claude/worktrees/live" SourcePackages Logs)")" worktree-live
git -C "$clone" worktree add -q --detach "$tmp/outside"
check "registered worktree outside .claude/worktrees, packages only" \
    "$(status_of "$(arena_for "$tmp/outside" SourcePackages Logs)")" other
# Moved by hand: git lists the old path, and the project builds at the new one.
git -C "$clone" worktree add -q --detach "$clone/.claude/worktrees/hand"
mv "$clone/.claude/worktrees/hand" "$clone/.claude/worktrees/hand moved"
mkdir -p "$clone/.claude/worktrees/hand moved/Kernova.xcodeproj"
touch "$clone/.claude/worktrees/hand moved/Kernova.xcodeproj/project.pbxproj"
moved=$(arena_for "$clone/.claude/worktrees/hand moved" Logs)
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s</string></dict></plist>\n' \
    "$clone/.claude/worktrees/hand moved/Kernova.xcodeproj" >"$moved/info.plist"
check "worktree moved by hand, at its new path" "$(status_of "$moved")" worktree-live
gone=$(arena_for "$tmp/gone" SourcePackages Logs)
check "no checkout, packages only" "$(status_of "$gone")" unclaimed
check "no checkout, packages only: label" "$("$clone/Tools/arena-label.sh" "$gone")" 'packages only, no checkout here'
# Anything beyond the resolution is something no record explains.
check "no checkout, with build output" "$(status_of "$(arena_for "$tmp/gone-built" SourcePackages Build)")" unattributable
mkdir -p "$dd_root/Other-$(printf 'a%.0s' {1..28})/SourcePackages"
check "another project's arena" "$(status_of "$dd_root/Other-$(printf 'a%.0s' {1..28})")" unattributable

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s arena-label: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
