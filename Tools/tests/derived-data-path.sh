#!/usr/bin/env bash
# Fixture tests for Tools/derived-data-path.sh's arena names: arenas real
# xcodebuild named for fixed project paths, and spellings of one path that
# xcodebuild resolves to the same arena. `defaults` is faked first on PATH, so
# the machine's derived-data preference cannot change the answer.
#
# fixture reads: Tools/derived-data-path.sh Tools/lib/xcodebuild-flags.sh

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
mkdir -p "$tmp/fakes"
printf '#!/bin/bash\nexit 1\n' >"$tmp/fakes/defaults"
chmod +x "$tmp/fakes/defaults"
export PATH="$tmp/fakes:$PATH"

arena_name() { basename "$("$ROOT/Tools/derived-data-path.sh" "$1")"; }

# BUILD_DIR from `xcodebuild -scheme P -showBuildSettings` (Xcode 27.2) on a
# one-target project at each path, which no longer exists.
check "xcodebuild's arena, path with a space" \
    "$(arena_name '/tmp/kernova-arena-pin/With Space/Kernova.xcodeproj')" Kernova-bskgeyyrjvctyballmlqsycwjlfe
check "xcodebuild's arena, plain path" \
    "$(arena_name '/tmp/kernova-arena-pin/plain/Kernova.xcodeproj')" Kernova-bmyrfnlygcsgpoazktawpcpydycn

# mktemp answers under /var, a symlink to /private/var, and pwd -P spells it
# /private/var. xcodebuild names one arena for every spelling of an existing
# project: the one for its resolved path without /private, which is the arena
# of that literal path before anything exists there to resolve.
project="${tmp#/private}/real dir/Kernova.xcodeproj"
expected=$(arena_name "$project")
mkdir -p "$tmp/real dir/Kernova.xcodeproj"
ln -s "real dir" "$tmp/link"
check "the resolved spelling" "$(arena_name "$project")" "$expected"
check "a /private spelling" "$(arena_name "$tmp/real dir/Kernova.xcodeproj")" "$expected"
check "a symlinked spelling" "$(arena_name "$tmp/link/Kernova.xcodeproj")" "$expected"

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s derived-data-path: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
