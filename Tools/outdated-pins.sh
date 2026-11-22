#!/usr/bin/env bash
# Compares every pin Tools/lib/pins.sh finds with its upstream releases and
# reports each pin that is behind: the newest patch, minor and major release
# newer than it, each with its release notes and the edit that moves the pin
# there. swift.org's release feed lists Swift's releases; a git repository's
# release tags list every other pin's, as SwiftPM and `git clone --branch`
# see them.
#
# A pin that cannot be read or looked up fails the run once every pin has been
# tried, and nothing is written to --markdown or --summary, so a failed lookup
# never reads as a current pin.
#
# Usage: Tools/outdated-pins.sh [--markdown <file>] [--summary <file>]
#   --markdown  write the pins that are behind as the tracking issue's sections
#   --summary   append `verdict=clean` or `verdict=findings`, and
#               `behind=<count>`, in GITHUB_OUTPUT's form

set -uo pipefail

# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/pins.sh
. Tools/lib/pins.sh

swift_feed=https://www.swift.org/api/v1/install/releases.json

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

# A repository that moved or went private asks for credentials; fail instead.
export GIT_TERMINAL_PROMPT=0

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
sections="$scratch/sections.md"
: >"$sections"

failed=0 behind=0 total=0 current=''

# release_tags <URL> — the release tags of the git repository at <URL>.
release_tags() {
    local refs tags
    refs=$(git ls-remote --tags --refs "$1") || { echo "outdated-pins: git ls-remote $1 failed" >&2; return 1; }
    tags=$(printf '%s\n' "$refs" | awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' | grep -E "$pins_release_pattern")
    [ -n "$tags" ] || { echo "outdated-pins: $1 has no release tag" >&2; return 1; }
    printf '%s\n' "$tags"
}

release_notes() {
    local repository=${1%.git}
    case "$repository" in
        https://github.com/*) printf '%s/releases/tag/%s\n' "$repository" "$2" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# code_list <and|or> <item>... — the items in backticks, as an English list.
code_list() {
    local conjunction=$1 out='' i=0 item
    shift
    for item in "$@"; do
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then
            out="\`$item\`"
        elif [ "$i" -eq $# ]; then
            out="$out $conjunction \`$item\`"
        else
            out="$out, \`$item\`"
        fi
    done
    printf '%s' "$out"
}

# report_pin <name> <pinned> <where> <rows> — reports one pin, given a
# `<level><TAB><release><TAB><release notes><TAB><move>` row for each newer
# release; none means it is current.
report_pin() {
    local name=$1 pinned=$2 where=$3 rows=$4 level release notes move
    total=$((total + 1))
    if [ -z "$rows" ]; then
        pass "$name $pinned is current ($where)"
        current="$current${current:+, }$name $pinned"
        return
    fi
    behind=$((behind + 1))
    warn "$name $pinned ($where)"
    printf '### %s %s\n\nPinned in `%s`.\n\n' "$name" "$pinned" "$where" >>"$sections"
    while IFS=$'\t' read -r level release notes move; do
        value "$release, a $level release: $notes"
        detail "$move"
        printf -- '- **%s**, a %s release · [release notes](%s). %s\n' "$release" "$level" "$notes" "$move" >>"$sections"
    done <<<"$rows"
    printf '\n' >>"$sections"
}

# ---- swift.org -------------------------------------------------------------------

# swift_syntax_moves <major> <minor> — swift-syntax's major names the Swift
# release it parses, so a Swift release in another minor moves each manifest
# requiring it.
swift_syntax_moves() {
    local file identity manifests=()
    while IFS= read -r file; do
        while IFS=$'\t' read -r identity _ _; do
            [ "$identity" = swift-syntax ] || continue
            while IFS= read -r manifest; do manifests+=("$manifest"); done < <(requiring_manifests "$file" swift-syntax)
        done < <(resolved_pins "$file" 2>/dev/null)
    done < <(git ls-files '*Package.resolved')
    [ "${#manifests[@]}" -gt 0 ] || return 0
    printf ' swift-syntax names the Swift release it parses by its major, so also require `%s.0.0` in %s and run `make resolve-packages`.' \
        "$(($1 * 100 + $2))" "$(code_list and "${manifests[@]}")"
}

if pinned=$(swift_pin); then
    if ! feed=$(curl -fsS --max-time 60 "$swift_feed") || ! names=$(jq -er '.[].name' <<<"$feed"); then
        echo "outdated-pins: $swift_feed could not be read" >&2
        failed=$((failed + 1))
    else
        rows=$(newer_releases "$pinned" <<<"$names" | while read -r level release; do
            IFS=$'\t' read -r tag sdk_version sdk_checksum < <(jq -r --arg name "$release" \
                'map(select(.name == $name))[0] | [.tag, ((.platforms // [])[] | select(.platform == "static-sdk") | .version, .checksum)] | @tsv' <<<"$feed")
            move="Write \`$release\` to \`.swift-version\`, and in \`Tools/lib/static-linux-sdk.sh\` set \`STATIC_SDK_VERSION=$sdk_version\` and \`STATIC_SDK_CHECKSUM=$sdk_checksum\`."
            [ -n "$sdk_checksum" ] || move="swift.org lists no Static Linux SDK for $release, which \`Tools/lib/static-linux-sdk.sh\` pins with \`.swift-version\`."
            if [ "$level" != patch ]; then
                IFS=. read -r major minor _ <<<"$release"
                move="$move$(swift_syntax_moves "$major" "${minor:-0}")"
            fi
            printf '%s\t%s\t%s\t%s\n' "$level" "$release" "https://github.com/swiftlang/swift/releases/tag/$tag" "$move"
        done)
        report_pin 'Swift toolchain' "$pinned" .swift-version "$rows"
    fi
else
    failed=$((failed + 1))
fi

# ---- installers ------------------------------------------------------------------

while IFS= read -r installer; do
    declared=$(installer_pin "$installer") || { failed=$((failed + 1)); continue; }
    [ "$declared" != none ] || continue
    IFS=$'\t' read -r _ url variable pinned <<<"$declared"
    tags=$(release_tags "$url") || { failed=$((failed + 1)); continue; }
    rows=$(newer_releases "$pinned" <<<"$tags" | while read -r level release; do
        printf '%s\t%s\t%s\t%s\n' "$level" "$release" "$(release_notes "$url" "$release")" \
            "Set \`$variable='$release'\` in \`$installer\`."
    done)
    report_pin "$(basename "${url%.git}")" "$pinned" "$installer" "$rows"
done < <(pins_installers)

# ---- Package.resolved ------------------------------------------------------------

if files=$(reported_resolved_files); then
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        pins=$(resolved_pins "$file") || { failed=$((failed + 1)); continue; }
        while IFS=$'\t' read -r identity location pinned; do
            [ -n "$identity" ] || continue
            tags=$(release_tags "$location") || { failed=$((failed + 1)); continue; }
            manifests=()
            while IFS= read -r manifest; do manifests+=("$manifest"); done < <(requiring_manifests "$file" "$identity")
            rows=$(newer_releases "$pinned" <<<"$tags" | while read -r level release; do
                if [ "${#manifests[@]}" -eq 0 ]; then
                    move="No manifest here requires it: it moves to the newest release the packages requiring it admit when \`$file\` is deleted and \`make resolve-packages\` resolves every pin afresh."
                elif [ "$level" = major ]; then
                    move="Change its requirement to admit \`$release\` in $(code_list and "${manifests[@]}"), then run \`make resolve-packages\`."
                else
                    move="Raise its requirement's lower bound to \`$release\` in $(code_list or "${manifests[@]}"), then run \`make resolve-packages\`."
                fi
                printf '%s\t%s\t%s\t%s\n' "$level" "$release" "$(release_notes "$location" "$release")" "$move"
            done)
            report_pin "$identity" "$pinned" "$file" "$rows"
        done <<<"$pins"
    done <<<"$files"
else
    failed=$((failed + 1))
fi

# ---- verdict ---------------------------------------------------------------------

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
    { cat "$sections"; [ -z "$current" ] || printf 'Current: %s.\n' "$current"; } >"$markdown" || exit 1
fi
if [ -n "$summary" ]; then
    verdict=clean
    [ "$behind" -eq 0 ] || verdict=findings
    printf 'verdict=%s\nbehind=%s\n' "$verdict" "$behind" >>"$summary" || exit 1
fi
