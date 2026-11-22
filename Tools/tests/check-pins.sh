#!/usr/bin/env bash
# Fixture tests for Tools/check-pins.sh: which declarations it accepts, that it
# names each one that does not read, and that a Package.resolved in a
# directory Dependabot's swift ecosystem updates is left to Dependabot in each
# form dependabot.yml can name it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

resolved='Tools/Dep/Package.resolved'

# tree <name> — a checkout under $tmp/<name> whose every declaration reads:
# an installer pinning a tag, one pinning none, and a Package.resolved pinning
# a release.
tree() {
    local dir="$tmp/$1"
    mkdir -p "$dir/Tools/lib" "$dir/Tools/Dep" "$dir/.github"
    cp "$ROOT/Tools/check-pins.sh" "$dir/Tools/"
    cp "$ROOT/Tools/lib/pins.sh" "$ROOT/Tools/lib/output.sh" "$ROOT/Tools/lib/static-linux-sdk.sh" "$dir/Tools/lib/"
    echo 6.4.1 >"$dir/.swift-version"
    printf '#!/usr/bin/env bash\n# Installs thing.\n#\n# pin: git https://github.com/example/thing.git THING_VERSION\n\nTHING_VERSION=2.1.0\n' \
        >"$dir/Tools/install-thing.sh"
    printf '#!/usr/bin/env bash\n# pin: none — builds from the tree\n' >"$dir/Tools/install-local.sh"
    pins "$1" '"version" : "1.2.0"'
    printf 'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directory: /\n' >"$dir/.github/dependabot.yml"
}

# pins <name> <state> — $resolved under <name> holds one pin in that state.
pins() {
    printf '{ "pins" : [ { "identity" : "dep", "location" : "https://github.com/example/dep.git", "state" : { %s } } ], "version" : 3 }\n' \
        "$2" >"$tmp/$1/$resolved"
}

# expect <name> <want> — check-pins over the tree <name> passes when <want> is
# empty, and otherwise fails naming each of <want>'s `|`-separated fragments.
expect() {
    local name=$1 want=$2 output status fragment
    git -C "$tmp/$name" init -q && git -C "$tmp/$name" add -A
    output=$(cd "$tmp/$name" && bash Tools/check-pins.sh 2>&1)
    status=$?
    if [ -z "$want" ]; then
        [ "$status" -eq 0 ] || fail "$name: exited $status: $output"
        return
    fi
    [ "$status" -ne 0 ] || fail "$name: exited 0"
    IFS='|' read -ra fragments <<<"$want"
    for fragment in "${fragments[@]}"; do
        [[ $output == *"$fragment"* ]] || fail "$name: does not say '$fragment': $output"
    done
}

tree valid
expect valid ''

tree quoted-variable
sed -i.bak "s/^THING_VERSION=.*/THING_VERSION='v2.1.0'/" "$tmp/quoted-variable/Tools/install-thing.sh"
rm "$tmp/quoted-variable/Tools/install-thing.sh.bak"
expect quoted-variable ''

tree no-declaration
printf '#!/usr/bin/env bash\n# Installs other.\n\n# pin: none — after the header, so not its declaration\n' >"$tmp/no-declaration/Tools/install-other.sh"
expect no-declaration 'Tools/install-other.sh: the comment block it opens with declares no'

tree two-declarations
printf '#!/usr/bin/env bash\n# pin: none — builds from the tree\n# pin: none — twice\n' >"$tmp/two-declarations/Tools/install-local.sh"
expect two-declarations 'Tools/install-local.sh: declares more than one'

tree none-without-reason
printf '#!/usr/bin/env bash\n# pin: none\n' >"$tmp/none-without-reason/Tools/install-local.sh"
expect none-without-reason "Tools/install-local.sh: '# pin: none' is not"

tree git-without-variable
printf '#!/usr/bin/env bash\n# pin: git https://github.com/example/thing.git\nTHING_VERSION=2.1.0\n' >"$tmp/git-without-variable/Tools/install-thing.sh"
expect git-without-variable "Tools/install-thing.sh: '# pin: git https://github.com/example/thing.git' is not"

tree unassigned
sed -i.bak 's/^THING_VERSION=/    THING_VERSION=/' "$tmp/unassigned/Tools/install-thing.sh"
rm "$tmp/unassigned/Tools/install-thing.sh.bak"
expect unassigned 'Tools/install-thing.sh: declares THING_VERSION, which it never assigns'

tree assigned-twice
echo 'THING_VERSION=2.2.0' >>"$tmp/assigned-twice/Tools/install-thing.sh"
expect assigned-twice 'Tools/install-thing.sh: assigns THING_VERSION more than once'

tree not-a-release
sed -i.bak 's/^THING_VERSION=.*/THING_VERSION=0123abc/' "$tmp/not-a-release/Tools/install-thing.sh"
rm "$tmp/not-a-release/Tools/install-thing.sh.bak"
expect not-a-release "Tools/install-thing.sh: THING_VERSION is '0123abc', not a release tag"

tree swift-not-a-release
echo main >"$tmp/swift-not-a-release/.swift-version"
expect swift-not-a-release ".swift-version holds 'main', not a release"

tree revision-pin
pins revision-pin '"revision" : "0123456789012345678901234567890123456789", "branch" : "main"'
expect revision-pin "$resolved: dep is pinned to a revision, not a release"

tree unread-resolved
echo '{ "object" : { "pins" : [] }, "version" : 1 }' >"$tmp/unread-resolved/$resolved"
expect unread-resolved "$resolved: not a Package.resolved this reads"

# Every failure is named before the check fails.
tree several
echo main >"$tmp/several/.swift-version"
printf '#!/usr/bin/env bash\n' >"$tmp/several/Tools/install-other.sh"
pins several '"revision" : "0123456789012345678901234567890123456789"'
expect several ".swift-version holds 'main'|Tools/install-other.sh: the comment block|$resolved: dep is pinned to a revision"

# A Package.resolved Dependabot updates is its own, however dependabot.yml
# names its directory.
for form in list single quoted glob; do
    tree "dependabot-$form"
    pins "dependabot-$form" '"revision" : "0123456789012345678901234567890123456789"'
    case "$form" in
        list) entry=$'    directories:\n      # the tool packages\n      - /Tools/Dep\n    schedule:\n      interval: weekly' ;;
        single) entry='    directory: /Tools/Dep/' ;;
        quoted) entry='    directory: "/Tools/Dep"' ;;
        glob) entry=$'    directories:\n      - "/Tools/*"' ;;
    esac
    printf '  - package-ecosystem: swift\n%s\n' "$entry" >>"$tmp/dependabot-$form/.github/dependabot.yml"
    expect "dependabot-$form" ''
done

tree dependabot-other-directory
pins dependabot-other-directory '"revision" : "0123456789012345678901234567890123456789"'
printf '  - package-ecosystem: swift\n    directories:\n      - /Tools/Other\n' >>"$tmp/dependabot-other-directory/.github/dependabot.yml"
expect dependabot-other-directory "$resolved: dep is pinned to a revision"

tree dependabot-no-directory
printf '  - package-ecosystem: swift\n    schedule:\n      interval: weekly\n' >>"$tmp/dependabot-no-directory/.github/dependabot.yml"
expect dependabot-no-directory '.github/dependabot.yml: a swift entry names no directory this reads'

if [ "$FAIL" -gt 0 ]; then
    printf '%d check-pins fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'check-pins fixtures: all passed\n'
