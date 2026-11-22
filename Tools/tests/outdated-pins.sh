#!/usr/bin/env bash
# Fixture tests for Tools/outdated-pins.sh and newer_releases in
# Tools/lib/pins.sh: which newer release it reports at each level, the move it
# gives for each kind of pin, that a Package.resolved Dependabot updates is
# left out, and that a lookup that fails or finds no release fails the run and
# writes nothing. The upstreams are stubs: curl serves the fixture's swift.org
# feed and `git ls-remote` its tag lists.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }
check() { [ "$2" = "$3" ] || fail "$1: got '$2', wanted '$3'"; }
has() { [[ $2 == *"$3"* ]] || fail "$1: '$2' does not contain '$3'"; }
lacks() { [[ $2 != *"$3"* ]] || fail "$1: '$2' contains '$3'"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
real_git=$(command -v git)
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# ---- newer_releases --------------------------------------------------------------

# shellcheck source=../lib/pins.sh
. "$ROOT/Tools/lib/pins.sh"
newer() { printf '%s\n' "${@:2}" | newer_releases "$1" | paste -sd ' ' -; }

# Numeric, not lexical, order at every level; a prerelease or a non-release
# tag is never a release; a `v` is optional; the newest of each level wins.
check 'newest at each level' "$(newer 1.4.2 1.4.1 1.4.2 1.4.10 v1.4.11 1.4.12-beta.1 1.9.9 1.12.3 1.5.0 \
    2.0.0 10.1.0 protoc-artifactbundle-v31.1 latest)" 'patch v1.4.11 minor 1.12.3 major 10.1.0'
check 'a missing component is 0' "$(newer 6.4.1 6.3 6.4 6.4.0 6.4.1)" ''
check 'a pin of two components' "$(newer 6.4 6.4.1 6.5)" 'patch 6.4.1 minor 6.5'
check 'a pin written with v' "$(newer v3.8.0 3.8.0 3.7.4)" ''
check 'a repeated tag' "$(newer 1.2.3 1.2.4 1.2.4)" 'patch 1.2.4'

# Every release one step either side of 5.5.5 in each component: the level is
# the first component that differs, when the release's is the greater.
for major in 4 5 6; do
    for minor in 4 5 6; do
        for patch in 4 5 6; do
            want=''
            if [ "$major" -ne 5 ]; then
                [ "$major" -lt 5 ] || want='major'
            elif [ "$minor" -ne 5 ]; then
                [ "$minor" -lt 5 ] || want='minor'
            elif [ "$patch" -gt 5 ]; then
                want='patch'
            fi
            check "5.5.5 against $major.$minor.$patch" "$(newer 5.5.5 "$major.$minor.$patch")" \
                "${want:+$want $major.$minor.$patch}"
        done
    done
done

# ---- the report ------------------------------------------------------------------

repo="$tmp/repo"
mkdir -p "$repo/Tools/lib" "$repo/Tools/Dep" "$repo/Kit" "$repo/Core" "$repo/.github" \
    "$repo/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
cp "$ROOT/Tools/outdated-pins.sh" "$repo/Tools/"
cp "$ROOT/Tools/lib/pins.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/static-linux-sdk.sh" "$repo/Tools/lib/"
echo 6.4.1 >"$repo/.swift-version"
cat >"$repo/Tools/install-thing.sh" <<'EOF'
#!/usr/bin/env bash
# Installs thing.
#
# pin: git https://github.com/example/thing.git THING_VERSION

THING_VERSION='2.1.0'
EOF
cat >"$repo/Tools/install-local.sh" <<'EOF'
#!/usr/bin/env bash
# pin: none — builds from the tree
EOF
cat >"$repo/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'EOF'
{
  "pins" : [
    { "identity" : "direct", "kind" : "remoteSourceControl", "location" : "https://github.com/example/direct.git",
      "state" : { "revision" : "1111111111111111111111111111111111111111", "version" : "1.2.0" } },
    { "identity" : "transitive", "kind" : "remoteSourceControl", "location" : "https://github.com/example/transitive",
      "state" : { "revision" : "2222222222222222222222222222222222222222", "version" : "3.0.0" } },
    { "identity" : "current", "kind" : "remoteSourceControl", "location" : "https://github.com/example/current.git",
      "state" : { "revision" : "3333333333333333333333333333333333333333", "version" : "4.0.0" } }
  ],
  "version" : 3
}
EOF
# Two top-level packages require direct, one spelling it in another case and
# without .git; neither requires transitive.
echo '.package(url: "https://github.com/example/direct.git", from: "1.2.0")' >"$repo/Kit/Package.swift"
echo '.package(url: "https://github.com/Example/Direct", "1.0.0"..<"2.0.0")' >"$repo/Core/Package.swift"
echo '.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")' >"$repo/Tools/Dep/Package.swift"
cat >"$repo/Tools/Dep/Package.resolved" <<'EOF'
{
  "pins" : [
    { "identity" : "swift-syntax", "kind" : "remoteSourceControl", "location" : "https://github.com/swiftlang/swift-syntax.git",
      "state" : { "revision" : "4444444444444444444444444444444444444444", "version" : "604.0.0" } }
  ],
  "version" : 3
}
EOF
cat >"$repo/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directories:
      - /
  - package-ecosystem: swift
    directories:
      - /Tools/Dep
EOF
git -C "$repo" init -q && git -C "$repo" add -A

stubs="$tmp/stubs"
mkdir -p "$stubs"
# curl serves $FIXTURE/feed.json for swift.org's feed while it exists.
cat >"$stubs/curl" <<'EOF'
#!/bin/bash
for url; do :; done
[ "$url" = https://www.swift.org/api/v1/install/releases.json ] && [ -f "$FIXTURE/feed.json" ] || exit 22
cat "$FIXTURE/feed.json"
EOF
# `git ls-remote` logs the URL and serves $FIXTURE/tags/<URL with / as _> as
# refs while it exists; every other git command is git's own.
cat >"$stubs/git" <<'EOF'
#!/bin/bash
[ "$1" = ls-remote ] || exec "$REAL_GIT" "$@"
for url; do :; done
echo "$url" >>"$FIXTURE/ls-remote.log"
tags="$FIXTURE/tags/$(printf '%s' "$url" | tr '/:' '__')"
[ -f "$tags" ] || exit 128
while read -r tag; do printf '%040d\trefs/tags/%s\n' 0 "$tag"; done <"$tags"
EOF
chmod +x "$stubs"/*
export FIXTURE="$tmp" REAL_GIT="$real_git" PATH="$stubs:$PATH"

tags() { mkdir -p "$tmp/tags"; printf '%s\n' "${@:2}" >"$tmp/tags/$(printf '%s' "$1" | tr '/:' '__')"; }
release() { printf '{"name": "%s", "tag": "swift-%s-RELEASE", "platforms": [%s]}' "$1" "$1" "${2:-}"; }
static_sdk() { printf '{"name": "Static SDK", "platform": "static-sdk", "version": "%s", "checksum": "%s"}' "$1" "$2"; }

reset() {
    rm -rf "$tmp/tags" "$tmp/ls-remote.log" "$tmp/out.md" "$tmp/summary"
    printf '[%s, %s, %s, %s]\n' "$(release 6.4.0)" "$(release 6.4.1)" \
        "$(release 6.4.3 "$(static_sdk 0.1.0 aaaa)")" "$(release 6.5 "$(static_sdk 0.2.0 bbbb)")" >"$tmp/feed.json"
    tags https://github.com/example/thing.git 2.0.0 2.1.0 2.1.1 3.0.0
    tags https://github.com/example/direct.git 1.2.0 1.3.0 2.0.0
    tags https://github.com/example/transitive 3.0.0 3.0.5
    tags https://github.com/example/current.git 4.0.0 4.0.0-rc.1
    tags https://github.com/swiftlang/swift-syntax.git 604.0.0 604.0.1
}
run() { (cd "$repo" && bash Tools/outdated-pins.sh --markdown "$tmp/out.md" --summary "$tmp/summary" 2>"$tmp/err" >"$tmp/out"); }
# row <pin> <release> — the line the markdown gives that release under that pin's section.
row() {
    awk -v pin="### $1 " -v release="- **$2**," '
        index($0, "### ") == 1 { inside = index($0, pin) == 1 }
        inside && index($0, release) == 1
    ' "$tmp/out.md"
}

reset
run
check 'behind: exit status' "$?" 0
check 'behind: summary' "$(cat "$tmp/summary")" $'verdict=findings\nbehind=4'
check 'behind: sections' "$(grep '^### ' "$tmp/out.md" | paste -sd '|' -)" \
    '### Swift toolchain 6.4.1|### thing 2.1.0|### direct 1.2.0|### transitive 3.0.0'
check 'behind: releases' "$(grep -o '^- \*\*[^*]*\*\*, an* [a-z]*' "$tmp/out.md" | paste -sd '|' -)" \
    '- **6.4.3**, a patch|- **6.5**, a minor|- **2.1.1**, a patch|- **3.0.0**, a major|- **1.3.0**, a minor|- **2.0.0**, a major|- **3.0.5**, a patch'
check 'behind: current pins' "$(tail -1 "$tmp/out.md")" 'Current: current 4.0.0.'

line=$(row 'Swift toolchain' 6.4.3)
has 'swift patch: release notes' "$line" '(https://github.com/swiftlang/swift/releases/tag/swift-6.4.3-RELEASE)'
has 'swift patch: its own SDK' "$line" '`STATIC_SDK_VERSION=0.1.0` and `STATIC_SDK_CHECKSUM=aaaa`'
lacks 'swift patch: swift-syntax keeps its major' "$line" swift-syntax
line=$(row 'Swift toolchain' 6.5)
has 'swift minor: .swift-version' "$line" 'Write `6.5` to `.swift-version`'
has 'swift minor: its own SDK' "$line" '`STATIC_SDK_VERSION=0.2.0` and `STATIC_SDK_CHECKSUM=bbbb`'
has 'swift minor: swift-syntax follows' "$line" 'require `605.0.0` in `Tools/Dep/Package.swift`'

has 'installer: release notes' "$(row thing 2.1.1)" '(https://github.com/example/thing/releases/tag/2.1.1)'
has 'installer: move' "$(row thing 2.1.1)" "Set \`THING_VERSION='2.1.1'\` in \`Tools/install-thing.sh\`."
has 'package minor: either manifest' "$(row direct 1.3.0)" 'to `1.3.0` in `Core/Package.swift` or `Kit/Package.swift`'
has 'package major: every manifest' "$(row direct 2.0.0)" 'admit `2.0.0` in `Core/Package.swift` and `Kit/Package.swift`'
has 'package transitive: no manifest' "$(row transitive 3.0.5)" 'No manifest here requires it'
has 'package transitive: release notes' "$(row transitive 3.0.5)" '(https://github.com/example/transitive/releases/tag/3.0.5)'
lacks 'dependabot: never looked up' "$(cat "$tmp/ls-remote.log")" swift-syntax
lacks 'dependabot: never reported' "$(grep '^### ' "$tmp/out.md")" swift-syntax

# Everything current: a clean verdict, and the markdown lists only what is current.
reset
printf '[%s]\n' "$(release 6.4.1)" >"$tmp/feed.json"
tags https://github.com/example/thing.git 2.1.0
tags https://github.com/example/direct.git 1.2.0
tags https://github.com/example/transitive 3.0.0 2.9.0
run
check 'current: exit status' "$?" 0
check 'current: summary' "$(cat "$tmp/summary")" $'verdict=clean\nbehind=0'
check 'current: markdown' "$(cat "$tmp/out.md")" 'Current: Swift toolchain 6.4.1, thing 2.1.0, direct 1.2.0, transitive 3.0.0, current 4.0.0.'

# A lookup that fails, or finds no release, fails the run and writes nothing.
expect_unread() {
    local name=$1 want=$2 status
    run
    status=$?
    [ "$status" -ne 0 ] || fail "$name: exited 0"
    [ ! -e "$tmp/out.md" ] || fail "$name: wrote the markdown"
    [ ! -e "$tmp/summary" ] || fail "$name: wrote the summary"
    has "$name: names it" "$(cat "$tmp/err")" "$want"
}
reset
rm "$tmp/feed.json"
expect_unread 'swift.org unreachable' 'https://www.swift.org/api/v1/install/releases.json could not be read'
reset
echo '{"releases": []}' >"$tmp/feed.json"
expect_unread 'swift.org feed unread' 'https://www.swift.org/api/v1/install/releases.json could not be read'
reset
echo '[]' >"$tmp/feed.json"
expect_unread 'swift.org feed empty' 'https://www.swift.org/api/v1/install/releases.json could not be read'
reset
rm "$tmp/tags/https___github.com_example_thing.git"
expect_unread 'installer repository unreachable' 'git ls-remote https://github.com/example/thing.git failed'
reset
tags https://github.com/example/direct.git 1.3.0-beta.1 nightly
expect_unread 'package with no release' 'https://github.com/example/direct.git has no release tag'

if [ "$FAIL" -gt 0 ]; then
    printf '%d outdated-pins fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'outdated-pins fixtures: all passed\n'
