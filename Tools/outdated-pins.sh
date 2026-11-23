#!/usr/bin/env bash
# Compares each pinned version with its upstream's newest release, and reports
# the pins that are behind, with the release notes and the edit that moves
# each one:
#
# - the swift.org release .swift-version names, against swift.org's release
#   feed; Tools/lib/static-linux-sdk.sh pins the Static Linux SDK built for it.
# - Periphery, the one tool an installer pins itself, against its
#   repository's release tags.
# - each version in a tracked Package.resolved outside the directories
#   .github/dependabot.yml gives the swift ecosystem, against its repository's
#   release tags.
#
# A lookup fails unless the upstream lists the pinned release itself. A
# failure fails the run once every pin has been tried, and nothing is written
# to --markdown or --summary, so it never reads as a current pin.
#
# Usage: Tools/outdated-pins.sh [--markdown <file>] [--summary <file>]
#   --markdown  write the pins that are behind as the tracking issue's sections
#   --summary   append `verdict=clean` or `verdict=findings`, and
#               `behind=<count>`, in GITHUB_OUTPUT's form

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/static-linux-sdk.sh
. Tools/lib/static-linux-sdk.sh

swift_feed=https://www.swift.org/api/v1/install/releases.json
periphery_repository=https://github.com/peripheryapp/periphery.git
not_checked='Not checked: Ubuntu 24.04 (noble), which the Linux CI images and the Ubuntu SDK target; the Xcode the runner image carries; runner labels; swiftly and the Homebrew tools, which are unpinned.'

markdown='' summary=''
while [ $# -gt 0 ]; do
    case "$1" in
        --markdown | --summary)
            [ $# -ge 2 ] || { echo "outdated-pins: $1 takes a file" >&2; exit 2; }
            if [ "$1" = --markdown ]; then markdown=$2; else summary=$2; fi
            shift 2
            ;;
        *)
            echo 'usage: Tools/outdated-pins.sh [--markdown <file>] [--summary <file>]' >&2
            exit 2
            ;;
    esac
done

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
sections="$scratch/sections.md"
: >"$sections"

failed=0 behind=0 total=0 current=''
unread() { echo "outdated-pins: $1" >&2; }

# ---- releases --------------------------------------------------------------------

# A release: one to three dot-separated numbers. A prerelease, or any other
# tag, is not one.
release_pattern='^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$'

# The awk every comparison below shares: parse(v, out) reads a release into
# out[1..3], a missing component as 0 so 6.4 is 6.4.0; cmp(a, b) is below,
# at or above 0 as a is older than, the same as or newer than b.
versions_awk='
    function parse(v, out,   n, part) {
        n = split(v, part, ".")
        out[1] = part[1] + 0; out[2] = (n >= 2 ? part[2] : 0) + 0; out[3] = (n >= 3 ? part[3] : 0) + 0
    }
    function cmp(a, b) { return a[1] != b[1] ? a[1] - b[1] : a[2] != b[2] ? a[2] - b[2] : a[3] - b[3] }
'

# has_release <pinned> — whether <pinned> is a release, and the releases on
# stdin include it.
has_release() {
    grep -Eq "$release_pattern" <<<"$1" || return 1
    awk -v pinned="$1" "$versions_awk"'
        BEGIN { parse(pinned, p) }
        { parse($0, v); if (cmp(v, p) == 0) found = 1 }
        END { exit !found }'
}

# newest_release — the newest of the releases on stdin.
newest_release() {
    awk "$versions_awk"'
        { parse($0, v); if (best == "" || cmp(v, b) > 0) { best = $0; parse($0, b) } }
        END { if (best != "") print best }'
}

# release_level <pinned> <release> — patch, minor or major, as the first
# component in which <release> is newer; nothing when it is not newer.
release_level() {
    awk -v pinned="$1" -v release="$2" "$versions_awk"'
        BEGIN {
            parse(pinned, p); parse(release, v)
            if (cmp(v, p) > 0) print (v[1] != p[1] ? "major" : v[2] != p[2] ? "minor" : "patch")
        }'
}

# release_tags <URL> <pinned> — the release tags of the git repository at
# <URL>, which must include <pinned>.
release_tags() {
    local refs tags
    refs=$(git ls-remote --tags --refs "$1") || { unread "git ls-remote $1 failed"; return 1; }
    tags=$(printf '%s\n' "$refs" | awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' | grep -E "$release_pattern")
    has_release "$2" <<<"$tags" || { unread "$1 has no release $2, the pinned one"; return 1; }
    printf '%s\n' "$tags"
}

# ---- the report ------------------------------------------------------------------

# report_pin <name> <pinned> <where> <level> <release> <release notes> <move>
# — reports one pin, behind <release> by <level>, or current when <level> is
# empty.
report_pin() {
    local name=$1 pinned=$2 where=$3 level=$4 release=$5 notes=$6 move=$7
    total=$((total + 1))
    if [ -z "$level" ]; then
        pass "$name $pinned is current ($where)"
        current="$current${current:+, }$name $pinned"
        return
    fi
    behind=$((behind + 1))
    warn "$name $pinned ($where)"
    value "$release, a $level release: $notes"
    detail "$move"
    printf '### %s %s\n\nPinned in `%s`.\n\n- **%s**, a %s release · [release notes](%s). %s\n\n' \
        "$name" "$pinned" "$where" "$release" "$level" "$notes" "$move" >>"$sections"
}

# ---- Swift -----------------------------------------------------------------------

if ! pinned=$(pinned_swift_version) || ! feed=$(curl -fsS --max-time 60 "$swift_feed") ||
    ! names=$(jq -r '.[].name' <<<"$feed" | grep -E "$release_pattern") || ! has_release "$pinned" <<<"$names"; then
    unread "$swift_feed could not be read, or lists no release ${pinned:-}, the one .swift-version names"
    failed=$((failed + 1))
else
    newest=$(newest_release <<<"$names")
    IFS=$'\t' read -r tag sdk_version sdk_checksum < <(jq -r --arg name "$newest" \
        'map(select(.name == $name))[0] | [.tag, (.platforms[] | select(.platform == "static-sdk") | .version, .checksum)] | @tsv' <<<"$feed")
    report_pin 'Swift toolchain' "$pinned" .swift-version "$(release_level "$pinned" "$newest")" "$newest" \
        "https://github.com/swiftlang/swift/releases/tag/$tag" \
        "Write \`$newest\` to \`.swift-version\`, and in \`Tools/lib/static-linux-sdk.sh\` set \`STATIC_SDK_VERSION=$sdk_version\` and \`STATIC_SDK_CHECKSUM=$sdk_checksum\`."
fi

# ---- Periphery -------------------------------------------------------------------

if ! pinned=$(Tools/install-periphery.sh --version) || ! tags=$(release_tags "$periphery_repository" "$pinned"); then
    failed=$((failed + 1))
else
    newest=$(newest_release <<<"$tags")
    report_pin Periphery "$pinned" Tools/install-periphery.sh "$(release_level "$pinned" "$newest")" "$newest" \
        "${periphery_repository%.git}/releases/tag/$newest" "Set \`PERIPHERY_VERSION='$newest'\` in \`Tools/install-periphery.sh\`."
fi

# ---- Package.resolved ------------------------------------------------------------

# reported_resolved_files — every tracked Package.resolved but those in a
# directory .github/dependabot.yml lists for the swift ecosystem.
reported_resolved_files() {
    local covered file
    covered=$(awk '
        /^  - package-ecosystem:/ { swift = $3 == "swift"; listing = 0; next }
        swift && listing && /^      - / { print $2; next }
        { listing = swift && /^    directories:/ }
    ' .github/dependabot.yml) || return 1
    git ls-files '*Package.resolved' | while IFS= read -r file; do
        grep -qxF "/$(dirname "$file")" <<<"$covered" || printf '%s\n' "$file"
    done
}

# `make resolve-packages` moves a pin only when a requirement on it changes
# (SwiftPM keeps every pin while the file's originHash matches), and then to
# the newest release the requirements admit; so raising one lower bound to
# the newest release, with every requirement admitting it, moves the pin
# there.
if files=$(reported_resolved_files) && pins=$(while IFS= read -r file; do
    jq -r --arg file "$file" '.pins[] | [$file, .identity, .location, (.state.version // "")] | @tsv' "$file" || exit 1
done <<<"$files"); then
    while IFS=$'\t' read -r file identity location pinned; do
        [ -n "$identity" ] || continue
        tags=$(release_tags "$location" "$pinned") || { failed=$((failed + 1)); continue; }
        newest=$(newest_release <<<"$tags")
        manifests=$(git ls-files '*Package.swift' | xargs grep -liF "${location%.git}" | sed 's/.*/`&`/' | paste -sd ',' - | sed 's/,/, /g')
        after=''
        # The Swift generated from each schema is checked in beside it, by
        # the protoc-gen-swift of the pinned revision.
        [ "$identity" != swift-protobuf ] || after=' Then regenerate the checked-in Swift with `Tools/regen-protos.sh`.'
        report_pin "$identity" "$pinned" "$file" "$(release_level "$pinned" "$newest")" "$newest" \
            "${location%.git}/releases/tag/$newest" \
            "${manifests:+In $manifests, }make every requirement on it admit \`$newest\` and raise at least one lower bound to \`$newest\`, then run \`make resolve-packages\`.$after"
    done <<<"$pins"
else
    unread 'a Package.resolved, or .github/dependabot.yml, could not be read'
    failed=$((failed + 1))
fi

# ---- verdict ---------------------------------------------------------------------

detail "$not_checked"
if [ "$failed" -gt 0 ]; then
    echo "outdated-pins: $failed pin source(s) could not be read or looked up, so nothing is reported" >&2
    exit 1
fi

if [ "$behind" -eq 0 ]; then
    pass "outdated pins: all $total pins are at their newest release"
else
    warn "outdated pins: $behind of $total pins are behind upstream"
fi

if [ -n "$markdown" ]; then
    {
        cat "$sections"
        [ -z "$current" ] || printf 'Current: %s.\n\n' "$current"
        printf '%s\n' "$not_checked"
    } >"$markdown" || exit 1
fi
if [ -n "$summary" ]; then
    verdict=clean
    [ "$behind" -eq 0 ] || verdict=findings
    printf 'verdict=%s\nbehind=%s\n' "$verdict" "$behind" >>"$summary" || exit 1
fi
