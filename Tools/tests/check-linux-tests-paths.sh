#!/usr/bin/env bash
# Fixture tests for Tools/check-linux-tests-paths.sh: which `paths` filters in
# a portable.yml it passes — the inputs exactly, as one list or as a list and
# its alias — and which it fails, naming the line: an input missing, an extra
# entry, a directory without `/**`, an alias of no list, a second list that
# differs; and an input git does not track.

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

repo="$tmp/repo"
git init -q -b main "$repo"
mkdir -p "$repo/Tools/lib" "$repo/.github/workflows" "$repo/KernovaKit/Sources" \
    "$repo/KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk" "$repo/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
cp "$ROOT/Tools/check-linux-tests-paths.sh" "$ROOT/Tools/test-linux.sh" "$repo/Tools/"
cp "$ROOT/Tools/lib/linux-tests.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/package-pins.sh" "$repo/Tools/lib/"
for file in .swift-version Tools/linux-tests.Containerfile KernovaKit/Package.swift KernovaKit/Sources/A.swift \
    KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh \
    Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
    echo x >"$repo/$file"
done
git -C "$repo" add -A

# The filter entries the inputs above make, in a portable.yml list.
entries="      - '.github/workflows/**'
      - '.swift-version'
      - 'Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
      - 'KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh'
      - 'KernovaKit/**'
      - 'Tools/lib/linux-tests.sh'
      - 'Tools/lib/package-pins.sh'
      - 'Tools/linux-tests.Containerfile'
      - 'Tools/test-linux.sh'"

# expect <name> <flagged lines> <portable.yml> — the check over <portable.yml>
# flags exactly the workflow lines given (space-separated, empty for a pass),
# and exits non-zero exactly when it flags one.
expect() {
    local output status got
    printf '%s\n' "$3" >"$repo/.github/workflows/portable.yml"
    output=$(cd "$repo" && bash Tools/check-linux-tests-paths.sh 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n 's|^check-linux-tests-paths: .github/workflows/portable.yml:\([0-9]*\) .*|\1|p' | paste -sd ' ' -)
    check "$1: flagged lines" "$got" "$2"
    check "$1: status" "$([ "$status" -eq 0 ] && echo pass || echo fail)" "$([ -z "$2" ] && echo pass || echo fail)"
}

expect 'a list and its alias' '' "on:
  push:
    paths: &inputs
$entries
  pull_request:
    paths: *inputs
  workflow_dispatch:"

expect 'two equal lists, double-quoted' '' "on:
  push:
    paths:
$(printf '%s\n' "$entries" | tr "'" '"')
  pull_request:
    paths:
$entries"

expect 'an input missing' 3 "on:
  push:
    paths: &inputs
$(printf '%s\n' "$entries" | grep -v agent-disk)
  pull_request:
    paths: *inputs"

expect 'an extra entry' 3 "on:
  push:
    paths: &inputs
$entries
      - 'Tools/lib/output.sh'
  pull_request:
    paths: *inputs"

expect 'a directory without /**' 3 "on:
  push:
    paths: &inputs
$(printf '%s\n' "$entries" | sed "s|'KernovaKit/\*\*'|'KernovaKit'|")
  pull_request:
    paths: *inputs"

expect 'an alias of no list' 14 "on:
  push:
    paths: &inputs
$entries
  pull_request:
    paths: *other"

expect 'a second list that differs' 14 "on:
  push:
    paths:
$entries
  pull_request:
    paths:
$(printf '%s\n' "$entries" | grep -v Containerfile)"

printf 'on:\n  workflow_dispatch:\n' >"$repo/.github/workflows/portable.yml"
output=$(cd "$repo" && bash Tools/check-linux-tests-paths.sh 2>&1)
check 'no filter: status' "$?" 1
check 'no filter: message' "$output" 'check-linux-tests-paths: .github/workflows/portable.yml has no paths filter'

git -C "$repo" rm -q --cached KernovaKit/Sources/A.swift KernovaKit/Package.swift
printf '%s\n' "on:
  push:
    paths: &inputs
$(printf '%s\n' "$entries" | grep -v KernovaKit)
  pull_request:
    paths: *inputs" >"$repo/.github/workflows/portable.yml"
output=$(cd "$repo" && bash Tools/check-linux-tests-paths.sh 2>&1)
check 'an untracked input: status' "$?" 1
check 'an untracked input: message' "$output" 'check-linux-tests-paths: Tools/lib/linux-tests.sh names KernovaKit, which git does not track'

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s check-linux-tests-paths: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
