#!/usr/bin/env bash
# Fixture tests for Tools/outdated-pins.sh: which newer release it reports for
# each pin and at which level, the move it gives against each requirement form,
# which Package.resolved files it leaves to Dependabot, and that a lookup that
# fails, or whose upstream does not list the pinned release, fails the run and
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

workspace='App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
repo="$tmp/repo"
mkdir -p "$repo/Tools/lib" "$repo/Tools/Dep" "$repo/Kit" "$repo/Core" "$repo/.github" "$repo/$(dirname "$workspace")"
cp "$ROOT/Tools/outdated-pins.sh" "$repo/Tools/"
cp "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/static-linux-sdk.sh" "$repo/Tools/lib/"
printf '#!/bin/bash\n[ "$1" = --version ] && cat "$FIXTURE/periphery.version"\n' >"$repo/Tools/install-periphery.sh"
chmod +x "$repo/Tools/install-periphery.sh"
# Every requirement form: up to the next major, written both ways; a
# half-open and a closed range; up to the next minor; exact. A commented-out
# one is not a requirement.
cat >"$repo/Kit/Package.swift" <<'EOF'
let package = Package(dependencies: [
    // .package(url: "https://github.com/example/direct.git", exact: "1.2.0"),
    .package(url: "https://github.com/example/direct.git", from: "1.2.0"),
    .package(
        url: "https://github.com/example/narrow.git", .upToNextMinor(from: "3.1.0")),
    .package(url: "https://github.com/example/exact.git", exact: "5.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    .package(url: "https://github.com/example/current.git", .upToNextMajor(from: "4.0.0")),
    .package(url: "https://github.com/example/within.git", from: "2.0.0"),
    .package(url: "https://github.com/example/closed.git", from: "4.0.0"),
])
EOF
cat >"$repo/Core/Package.swift" <<'EOF'
let package = Package(dependencies: [
    .package(path: "../Kit"),
    .package(url: "https://github.com/Example/Direct", "1.0.0"..<"2.0.0"),
    .package(url: "https://github.com/example/closed.git", "4.0.0"..."4.2.0"),
])
EOF
echo '.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")' >"$repo/Tools/Dep/Package.swift"
cat >"$repo/Tools/Dep/Package.resolved" <<'EOF'
{ "pins" : [ { "identity" : "swift-syntax", "location" : "https://github.com/swiftlang/swift-syntax.git",
  "state" : { "revision" : "4444444444444444444444444444444444444444", "version" : "604.0.0" } } ], "version" : 3 }
EOF
printf '{ "pins" : [], "version" : 3 }\n' >"$repo/$workspace"
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
# `git ls-remote` logs the URL and serves $FIXTURE/tags/<URL with / and : as _>
# as refs while it exists; every other git command is git's own.
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
feed() { local IFS=,; printf '[%s]\n' "$*" >"$tmp/feed.json"; }
# pins <identity>=<version>... — the workspace's Package.resolved, each pin at
# https://github.com/example/<identity>.git but swift-protobuf at apple's.
pins() {
    local pin identity entries=()
    for pin; do
        identity=${pin%%=*}
        entries+=("$(printf '{ "identity" : "%s", "location" : "%s", "state" : { "revision" : "%040d", "version" : "%s" } }' \
            "$identity" "$(url "$identity")" 0 "${pin#*=}")")
    done
    local IFS=,
    printf '{ "pins" : [ %s ], "version" : 3 }\n' "${entries[*]}" >"$repo/$workspace"
}
url() { case "$1" in swift-protobuf) echo https://github.com/apple/swift-protobuf.git ;; *) echo "https://github.com/example/$1.git" ;; esac; }
dependabot() { printf 'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directories:\n      - /\n%s\n' "$1" >"$repo/.github/dependabot.yml"; }

reset() {
    rm -rf "$tmp/tags" "$tmp/ls-remote.log" "$tmp/out.md" "$tmp/summary"
    echo 6.4.1 >"$repo/.swift-version"
    feed "$(release 6.4.0)" "$(release 6.4.1)" "$(release 6.4.3 "$(static_sdk 0.1.0 aaaa)")" "$(release 6.5 "$(static_sdk 0.2.0 bbbb)")"
    echo 3.8.0 >"$tmp/periphery.version"
    tags https://github.com/peripheryapp/periphery.git 3.7.4 3.8.0 3.8.1 4.0.0
    pins current=4.0.0
    tags "$(url current)" 4.0.0 4.0.1-rc.1 5.0.0-beta
    tags https://github.com/swiftlang/swift-syntax.git 604.0.0 604.0.1
    dependabot $'  - package-ecosystem: swift\n    directories:\n      - /Tools/Dep'
}
run() { (cd "$repo" && bash Tools/outdated-pins.sh --markdown "$tmp/out.md" --summary "$tmp/summary" >/dev/null 2>&1); }
# row <pin> <release> — the line the markdown gives that release under that pin.
row() {
    awk -v pin="### $1 " -v release="- **$2**," '
        index($0, "### ") == 1 { inside = index($0, pin) == 1 }
        inside && index($0, release) == 1
    ' "$tmp/out.md"
}
# releases <pin> — each `<release> <level>` the markdown lists under that pin.
releases() {
    awk -v pin="### $1 " '
        index($0, "### ") == 1 { inside = index($0, pin) == 1; next }
        inside && /^- \*\*/ {
            line = $0; sub(/^- \*\*/, "", line)
            release = line; sub(/\*\*.*/, "", release)
            level = line; sub(/^[^*]*\*\*, an? /, "", level); sub(/ .*/, "", level)
            print release, level
        }
    ' "$tmp/out.md" | paste -sd ' ' -
}

# ---- what is behind, and the moves -------------------------------------------------

reset
pins direct=1.2.0 narrow=3.1.0 exact=5.0.0 closed=4.0.0 swift-protobuf=1.39.0 within=2.0.0 transitive=3.0.0 current=4.0.0
tags "$(url direct)" 1.2.0 1.2.1 1.3.0 2.0.0 2.1.0
tags "$(url narrow)" 3.1.0 3.1.4 3.2.0
tags "$(url exact)" 5.0.0 5.0.1
tags "$(url closed)" 4.0.0 4.2.0 4.3.0
tags "$(url swift-protobuf)" 1.39.0 1.41.0 2.0.0
tags "$(url within)" 2.0.0 2.3.0
tags "$(url transitive)" 3.0.0 3.0.5
run
check 'behind: exit status' "$?" 0
check 'behind: summary' "$(cat "$tmp/summary")" $'verdict=findings\nbehind=9'
check 'behind: Swift' "$(releases 'Swift toolchain')" '6.4.3 patch 6.5 minor'
check 'behind: Periphery' "$(releases Periphery)" '3.8.1 patch 4.0.0 major'
# A package's rows are the newest release its requirements admit and the
# newest they exclude: what raising a lower bound, or widening, resolves to.
check 'behind: from and a half-open range' "$(releases direct)" '1.3.0 minor 2.1.0 major'
check 'behind: up to the next minor' "$(releases narrow)" '3.1.4 patch 3.2.0 minor'
check 'behind: exact' "$(releases exact)" '5.0.1 patch'
check 'behind: closed range' "$(releases closed)" '4.2.0 minor 4.3.0 minor'
check 'behind: from excludes the next major' "$(releases swift-protobuf)" '1.41.0 minor 2.0.0 major'
check 'behind: newest admitted' "$(releases within)" '2.3.0 minor'
check 'behind: no manifest requires it' "$(releases transitive)" '3.0.5 patch'
check 'behind: current' "$(grep '^Current: ' "$tmp/out.md")" 'Current: current 4.0.0.'
check 'behind: says what is not checked' "$(grep -c '^Not checked: ' "$tmp/out.md")" 1

line=$(row 'Swift toolchain' 6.4.3)
has 'swift patch: release notes' "$line" '(https://github.com/swiftlang/swift/releases/tag/swift-6.4.3-RELEASE)'
has 'swift patch: its own SDK' "$line" '`STATIC_SDK_VERSION=0.1.0` and `STATIC_SDK_CHECKSUM=aaaa`'
lacks 'swift patch: swift-syntax keeps its major' "$line" swift-syntax
line=$(row 'Swift toolchain' 6.5)
has 'swift minor: .swift-version' "$line" 'Write `6.5` to `.swift-version`'
has 'swift minor: its own SDK' "$line" '`STATIC_SDK_VERSION=0.2.0` and `STATIC_SDK_CHECKSUM=bbbb`'
has 'swift minor: swift-syntax follows' "$line" '`from: "605.0.0"` in `Tools/Dep/Package.swift`'
has 'periphery: release notes' "$(row Periphery 3.8.1)" '(https://github.com/peripheryapp/periphery/releases/tag/3.8.1)'
has 'periphery: move' "$(row Periphery 3.8.1)" "Set \`PERIPHERY_VERSION='3.8.1'\` in \`Tools/install-periphery.sh\`."
has 'direct in range: either manifest' "$(row direct 1.3.0)" 'lower bound to `1.3.0` in `Core/Package.swift` or `Kit/Package.swift`'
has 'direct excluded: every manifest' "$(row direct 2.1.0)" 'admit `2.1.0` in `Core/Package.swift` and `Kit/Package.swift`'
has 'narrow in range' "$(row narrow 3.1.4)" 'lower bound to `3.1.4` in `Kit/Package.swift`'
has 'narrow excluded' "$(row narrow 3.2.0)" 'admit `3.2.0` in `Kit/Package.swift`'
has 'exact excluded' "$(row exact 5.0.1)" 'admit `5.0.1` in `Kit/Package.swift`'
has 'closed in range' "$(row closed 4.2.0)" 'lower bound to `4.2.0` in `Core/Package.swift` or `Kit/Package.swift`'
has 'closed excluded: only the manifest excluding it' "$(row closed 4.3.0)" 'admit `4.3.0` in `Core/Package.swift`, then'
has 'swift-protobuf regenerates' "$(row swift-protobuf 1.41.0)" '`Tools/check-generated-protos.sh --write`'
has 'transitive: release notes' "$(row transitive 3.0.5)" '(https://github.com/example/transitive/releases/tag/3.0.5)'
has 'transitive: no manifest' "$(row transitive 3.0.5)" "deleting \`$workspace\`"
lacks 'dependabot: never looked up' "$(cat "$tmp/ls-remote.log")" swift-syntax
lacks 'dependabot: never reported' "$(grep '^### ' "$tmp/out.md")" swift-syntax

# ---- comparing releases ------------------------------------------------------------

# Numeric, not lexical, at every level; a prerelease or another tag is not a
# release; a `v` is optional; the newest at each level wins.
reset
echo 1.4.2 >"$tmp/periphery.version"
tags https://github.com/peripheryapp/periphery.git 1.4.1 1.4.2 1.4.10 v1.4.11 1.4.12-beta.1 1.9.9 1.12.3 1.5.0 \
    2.0.0 10.1.0 protoc-artifactbundle-v31.1 latest
run
check 'newest at each level' "$(releases Periphery)" 'v1.4.11 patch 1.12.3 minor 10.1.0 major'

# A missing component is 0, in the pin and in a release.
reset
feed "$(release 6.3)" "$(release 6.4)" "$(release 6.4.1)"
run
check 'a missing component is 0' "$(releases 'Swift toolchain')" ''
reset
echo 6.4 >"$repo/.swift-version"
feed "$(release 6.3)" "$(release 6.4.0)" "$(release 6.4.1)" "$(release 6.5)"
run
check 'a pin of two components' "$(releases 'Swift toolchain')" '6.4.1 patch 6.5 minor'

# Every release one step either side of 5.5.5 in each component: the level is
# the first component that differs, when the release's is the greater.
reset
sweep=()
for major in 4 5 6; do for minor in 4 5 6; do for patch in 4 5 6; do
    sweep+=("sweep-$major-$minor-$patch=5.5.5")
    tags "$(url "sweep-$major-$minor-$patch")" 5.5.5 "$major.$minor.$patch"
done; done; done
pins "${sweep[@]}"
run
for major in 4 5 6; do for minor in 4 5 6; do for patch in 4 5 6; do
    want=''
    if [ "$major" -ne 5 ]; then
        [ "$major" -lt 5 ] || want='major'
    elif [ "$minor" -ne 5 ]; then
        [ "$minor" -lt 5 ] || want='minor'
    elif [ "$patch" -gt 5 ]; then
        want='patch'
    fi
    check "5.5.5 against $major.$minor.$patch" "$(releases "sweep-$major-$minor-$patch")" "${want:+$major.$minor.$patch $want}"
done; done; done

# ---- Dependabot's directories ------------------------------------------------------

# Each way dependabot.yml can name the directory leaves its pins to Dependabot;
# another directory leaves them to this report.
for form in list single quoted glob other; do
    reset
    case "$form" in
        list) entry=$'    directories:\n      # the tool packages\n      - /Tools/Dep\n    schedule:\n      interval: weekly' ;;
        single) entry='    directory: /Tools/Dep/' ;;
        quoted) entry='    directory: "/Tools/Dep"' ;;
        glob) entry=$'    directories:\n      - "/Tools/*"' ;;
        other) entry=$'    directories:\n      - /Tools/Other' ;;
    esac
    dependabot "  - package-ecosystem: swift"$'\n'"$entry"
    run
    check "dependabot $form: exit status" "$?" 0
    if [ "$form" = other ]; then
        has "dependabot $form: reported" "$(cat "$tmp/ls-remote.log")" swift-syntax
    else
        lacks "dependabot $form: left to Dependabot" "$(cat "$tmp/ls-remote.log")" swift-syntax
    fi
done

# ---- nothing behind ----------------------------------------------------------------

reset
feed "$(release 6.4.1)"
tags https://github.com/peripheryapp/periphery.git 3.8.0
run
check 'current: exit status' "$?" 0
check 'current: summary' "$(cat "$tmp/summary")" $'verdict=clean\nbehind=0'
check 'current: pins' "$(grep '^Current: ' "$tmp/out.md")" 'Current: Swift toolchain 6.4.1, Periphery 3.8.0, current 4.0.0.'

# ---- what fails the run --------------------------------------------------------------

# Each fails the run and writes nothing: a lookup that cannot be read, an
# upstream that does not list the pinned release, and a pin or requirement
# this cannot read.
unread() {
    local status
    run
    status=$?
    [ "$status" -ne 0 ] || fail "$1: exited 0"
    [ ! -e "$tmp/out.md" ] || fail "$1: wrote the markdown"
    [ ! -e "$tmp/summary" ] || fail "$1: wrote the summary"
}
reset
rm "$tmp/feed.json"
unread 'swift.org unreachable'
reset
echo '{"releases": []}' >"$tmp/feed.json"
unread 'swift.org feed of another shape'
reset
echo '[]' >"$tmp/feed.json"
unread 'swift.org feed empty'
reset
feed '{"name": "swift-6.4.1-RELEASE"}' '{"name": "swift-6.4.3-RELEASE"}'
unread 'swift.org names of another shape'
reset
feed "$(release 6.3.3)"
unread 'swift.org feed without the pin'
reset
echo 6.4.1-RELEASE >"$repo/.swift-version"
unread '.swift-version not a release'
reset
rm "$tmp/tags/https___github.com_peripheryapp_periphery.git"
unread 'Periphery unreachable'
reset
tags https://github.com/peripheryapp/periphery.git 3.6.0 3.7.4
unread 'Periphery tags without the pin'
reset
tags "$(url current)" 4.0.1 5.0.0
unread 'package tags without the pin'
reset
pins current=4.0.0 transitive=3.0.0
unread 'package no manifest requires, unreachable'
reset
tags "$(url current)" 4.0.0-rc.1 nightly
unread 'package with no release'
reset
pins current=3.9.0
tags "$(url current)" 3.9.0 4.0.0
unread 'pin its requirements exclude'
reset
pins current=4.0.0 odd=1.0.0
tags "$(url odd)" 1.0.0
cp "$repo/Kit/Package.swift" "$tmp/Kit.swift"
printf '.package(url: "https://github.com/example/odd.git", from: oddVersion)\n' >>"$repo/Kit/Package.swift"
unread 'requirement form unread'
cp "$tmp/Kit.swift" "$repo/Kit/Package.swift"
reset
printf '{ "pins" : [ { "identity" : "current", "location" : "%s", "state" : { "revision" : "%040d", "branch" : "main" } } ], "version" : 3 }\n' \
    "$(url current)" 0 >"$repo/$workspace"
unread 'pin to a revision'
reset
dependabot $'  - package-ecosystem: swift\n    schedule:\n      interval: weekly'
unread 'dependabot swift entry without a directory'

if [ "$FAIL" -gt 0 ]; then
    printf '%d outdated-pins fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'outdated-pins fixtures: all passed\n'
