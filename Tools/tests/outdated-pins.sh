#!/usr/bin/env bash
# Fixture tests for Tools/outdated-pins.sh: which newest release it reports
# for each pin and at which level, the move it gives, which Package.resolved
# it leaves to Dependabot, and that a lookup that fails, or whose upstream does
# not list the pinned release, fails the run and writes nothing. The upstreams
# are stubs: curl serves the fixture's swift.org feed and `git ls-remote` its
# tag lists.

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
mkdir -p "$repo/Tools/lib" "$repo/Tools/Dep" "$repo/Kit" "$repo/Core" "$repo/Other" "$repo/.github" "$repo/$(dirname "$workspace")"
cp "$ROOT/Tools/outdated-pins.sh" "$repo/Tools/"
cp "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/static-linux-sdk.sh" "$repo/Tools/lib/"
printf '#!/bin/bash\n[ "$1" = --version ] && cat "$FIXTURE/periphery.version"\n' >"$repo/Tools/install-periphery.sh"
chmod +x "$repo/Tools/install-periphery.sh"
# Two manifests name swift-protobuf, one in another case and without .git.
echo '.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0")' >"$repo/Kit/Package.swift"
echo '.package(url: "https://github.com/Apple/Swift-Protobuf", "1.0.0"..<"2.0.0")' >"$repo/Core/Package.swift"
echo '.package(url: "https://github.com/example/current.git", from: "4.0.0")' >"$repo/Other/Package.swift"
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
release() { printf '{"name": "%s", "tag": "swift-%s-RELEASE", "platforms": [{"platform": "static-sdk", "version": "%s", "checksum": "%s"}]}' "$1" "$1" "${2:-0.1.0}" "${3:-0000}"; }
feed() { local IFS=,; printf '[%s]\n' "$*" >"$tmp/feed.json"; }
url() { case "$1" in swift-protobuf) echo https://github.com/apple/swift-protobuf.git ;; *) echo "https://github.com/example/$1.git" ;; esac; }
# pins <identity>=<version>... — the workspace's Package.resolved, each pin at url's location.
pins() {
    local pin entries=()
    for pin; do
        entries+=("$(printf '{ "identity" : "%s", "location" : "%s", "state" : { "revision" : "%040d", "version" : "%s" } }' \
            "${pin%%=*}" "$(url "${pin%%=*}")" 0 "${pin#*=}")")
    done
    local IFS=,
    printf '{ "pins" : [ %s ], "version" : 3 }\n' "${entries[*]}" >"$repo/$workspace"
}
dependabot() {
    printf 'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directories:\n      - /\n  - package-ecosystem: swift\n    directories:\n      - %s\n    ignore:\n      - dependency-name: x\n' \
        "$1" >"$repo/.github/dependabot.yml"
}

reset() {
    rm -rf "$tmp/tags" "$tmp/ls-remote.log" "$tmp/out.md" "$tmp/summary"
    echo 6.4.1 >"$repo/.swift-version"
    feed "$(release 6.4.1)"
    echo 3.8.0 >"$tmp/periphery.version"
    tags https://github.com/peripheryapp/periphery.git 3.7.4 3.8.0
    pins current=4.0.0
    tags "$(url current)" 4.0.0 4.0.1-rc.1
    tags https://github.com/swiftlang/swift-syntax.git 604.0.0 604.0.1
    dependabot /Tools/Dep
}
run() { (cd "$repo" && bash Tools/outdated-pins.sh --markdown "$tmp/out.md" --summary "$tmp/summary" >/dev/null 2>&1); }
# row <pin> — the line the markdown gives under that pin's section.
row() { awk -v pin="### $1 " 'index($0, "### ") == 1 { inside = index($0, pin) == 1; next } inside && /^- \*\*/' "$tmp/out.md"; }
# newest <pin> — `<release> <level>` from that pin's line, or nothing when it is current.
newest() { row "$1" | sed -E 's/^- \*\*([^*]*)\*\*, an? ([a-z]+) release.*/\1 \2/'; }

# ---- what is behind, and the moves ---------------------------------------------------

reset
feed "$(release 6.3)" "$(release 6.4.0)" "$(release 6.4.1)" "$(release 6.4.3 0.1.0 aaaa)" "$(release 6.5 0.2.0 bbbb)"
tags https://github.com/peripheryapp/periphery.git 3.7.4 3.8.0 3.8.1 4.0.0
pins swift-protobuf=1.39.0 current=4.0.0
tags "$(url swift-protobuf)" 1.39.0 1.41.0 protoc-artifactbundle-v31.1
run
check 'behind: exit status' "$?" 0
check 'behind: summary' "$(cat "$tmp/summary")" $'verdict=findings\nbehind=3'
check 'behind: Swift' "$(newest 'Swift toolchain')" '6.5 minor'
check 'behind: Periphery' "$(newest Periphery)" '4.0.0 major'
check 'behind: package' "$(newest swift-protobuf)" '1.41.0 minor'
check 'behind: current' "$(grep '^Current: ' "$tmp/out.md")" 'Current: current 4.0.0.'
check 'behind: says what is not checked' "$(grep -c '^Not checked: ' "$tmp/out.md")" 1
has 'swift: release notes' "$(row 'Swift toolchain')" '(https://github.com/swiftlang/swift/releases/tag/swift-6.5-RELEASE)'
has 'swift: the release and its own SDK' "$(row 'Swift toolchain')" \
    'Write `6.5` to `.swift-version`, and in `Tools/lib/static-linux-sdk.sh` set `STATIC_SDK_VERSION=0.2.0` and `STATIC_SDK_CHECKSUM=bbbb`'
has 'periphery: release notes' "$(row Periphery)" '(https://github.com/peripheryapp/periphery/releases/tag/4.0.0)'
has 'periphery: move' "$(row Periphery)" "Set \`PERIPHERY_VERSION='4.0.0'\` in \`Tools/install-periphery.sh\`."
has 'package: release notes' "$(row swift-protobuf)" '(https://github.com/apple/swift-protobuf/releases/tag/1.41.0)'
has 'package: the manifests naming it' "$(row swift-protobuf)" 'In `Core/Package.swift`, `Kit/Package.swift`, make'
has 'package: regenerates' "$(row swift-protobuf)" '`Tools/check-generated-protos.sh --write`'
lacks 'dependabot: never looked up' "$(cat "$tmp/ls-remote.log")" swift-syntax
lacks 'dependabot: never reported' "$(grep '^### ' "$tmp/out.md")" swift-syntax

# ---- comparing releases ------------------------------------------------------------

# Numeric, not lexical, in every component; a prerelease or another tag is not a release.
reset
echo 1.4.2 >"$tmp/periphery.version"
tags https://github.com/peripheryapp/periphery.git 1.4.2 1.9.9 1.12.3 2.0.0 10.1.0 10.2.0-beta.1 latest
run
check 'numeric major' "$(newest Periphery)" '10.1.0 major'
reset
echo 1.4.2 >"$tmp/periphery.version"
tags https://github.com/peripheryapp/periphery.git 1.4.2 1.4.9 1.4.10
run
check 'numeric patch' "$(newest Periphery)" '1.4.10 patch'

# A missing component is 0, in a release and in the pin.
reset
feed "$(release 6.3)" "$(release 6.4)" "$(release 6.4.1)"
run
check 'a release of two components' "$(newest 'Swift toolchain')" ''
reset
echo 6.4 >"$repo/.swift-version"
feed "$(release 6.4.0)" "$(release 6.4.1)"
run
check 'a pin of two components' "$(newest 'Swift toolchain')" '6.4.1 patch'

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
    check "5.5.5 against $major.$minor.$patch" "$(newest "sweep-$major-$minor-$patch")" "${want:+$major.$minor.$patch $want}"
done; done; done

# ---- Dependabot's directory --------------------------------------------------------

# A Package.resolved outside the directory dependabot.yml lists is this report's.
reset
dependabot /Tools/Other
run
check 'other directory: exit status' "$?" 0
has 'other directory: reported' "$(cat "$tmp/ls-remote.log")" swift-syntax

# ---- nothing behind ----------------------------------------------------------------

reset
run
check 'current: exit status' "$?" 0
check 'current: summary' "$(cat "$tmp/summary")" $'verdict=clean\nbehind=0'
check 'current: pins' "$(grep '^Current: ' "$tmp/out.md")" 'Current: Swift toolchain 6.4.1, Periphery 3.8.0, current 4.0.0.'

# ---- what fails the run --------------------------------------------------------------

# Each fails the run and writes nothing: a lookup that cannot be read, or an
# upstream that does not list the pinned release.
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
tags "$(url current)" 4.0.0-rc.1 nightly
unread 'package with no release'
reset
rm "$tmp/tags/$(url current | tr '/:' '__')"
unread 'package unreachable'
reset
printf '{ "pins" : [ { "identity" : "current", "location" : "%s", "state" : { "revision" : "%040d", "branch" : "main" } } ], "version" : 3 }\n' \
    "$(url current)" 0 >"$repo/$workspace"
unread 'pin to a revision'
reset
echo '{ "pins" : [' >"$repo/$workspace"
unread 'Package.resolved unreadable'

if [ "$FAIL" -gt 0 ]; then
    printf '%d outdated-pins fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'outdated-pins fixtures: all passed\n'
