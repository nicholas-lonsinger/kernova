#!/usr/bin/env bash
# Compares the pinned versions with their upstream releases and reports each
# one that is behind, with its release notes and the edit that moves it:
#
# - the swift.org release .swift-version names, against swift.org's release
#   feed; Tools/lib/static-linux-sdk.sh pins the Static Linux SDK built for it.
# - Periphery, the one tool an installer pins itself, against its
#   repository's release tags.
# - each version in a tracked Package.resolved outside the directories
#   .github/dependabot.yml gives the swift ecosystem, against its repository's
#   release tags, the versions SwiftPM resolves.
#
# For Swift and Periphery it lists the newest patch, minor and major release
# newer than the pin. For a package it lists the newest release the
# requirements resolved into that Package.resolved admit, and the newest one
# they exclude.
#
# A lookup fails unless the upstream lists the pinned release itself, and so
# does a requirement this cannot read. A failure fails the run once every pin
# has been tried, and nothing is written to --markdown or --summary, so it
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

# A repository that moved or went private asks for credentials; fail instead.
export GIT_TERMINAL_PROMPT=0

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
sections="$scratch/sections.md"
: >"$sections"

failed=0 behind=0 total=0 current=''
unread() { echo "outdated-pins: $1" >&2; }

# ---- releases --------------------------------------------------------------------

# A release: one to three dot-separated numbers, optionally after a `v`. A
# prerelease, or any other tag, is not one.
release_pattern='^v?[0-9]+(\.[0-9]+)?(\.[0-9]+)?$'

# The awk every comparison below shares: parse(v, out) reads a release into
# out[1..3], a missing component as 0 so 6.4 is 6.4.0; cmp(a, b) is below,
# at or above 0 as a is older than, the same as or newer than b.
versions_awk='
    function parse(v, out,   n, part) {
        sub(/^v/, "", v)
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

# newer_releases <pinned> — of the releases on stdin, the newest at each level
# that is newer than <pinned>, as `<level> <release>` lines: `patch`, same
# major and minor; `minor`, same major; then `major`.
newer_releases() {
    awk -v pinned="$1" "$versions_awk"'
        BEGIN { parse(pinned, p) }
        {
            parse($0, v)
            if (cmp(v, p) <= 0) next
            level = v[1] != p[1] ? "major" : v[2] != p[2] ? "minor" : "patch"
            if (level in best) { parse(best[level], b); if (cmp(v, b) <= 0) next }
            best[level] = $0
        }
        END { if ("patch" in best) print "patch", best["patch"]; if ("minor" in best) print "minor", best["minor"]; if ("major" in best) print "major", best["major"] }'
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

# admitted <lower> <upper> <closed> — the releases on stdin at or above
# <lower> and below <upper>, or at it when <closed> is 1.
admitted() {
    awk -v lower="$1" -v upper="$2" -v closed="$3" "$versions_awk"'
        BEGIN { parse(lower, lo); parse(upper, hi) }
        { parse($0, v); if (cmp(v, lo) >= 0 && (closed ? cmp(v, hi) <= 0 : cmp(v, hi) < 0)) print }'
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

release_notes() {
    local repository=${1%.git}
    case "$repository" in
        https://github.com/*) printf '%s/releases/tag/%s\n' "$repository" "$2" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# ---- packages --------------------------------------------------------------------

# dependabot_swift_directories — each directory .github/dependabot.yml gives
# the swift ecosystem, as written there. Fails when a swift entry names none
# this can read.
dependabot_swift_directories() {
    [ -f .github/dependabot.yml ] || return 0
    awk '
        function unquote(s) { gsub(/["\047]/, "", s); return s }
        /^  - package-ecosystem:/ {
            ecosystem = unquote($3); listing = 0
            if (ecosystem == "swift") { entries++; found[entries] = 0 }
            next
        }
        /^[^ #]/ { ecosystem = ""; next }
        ecosystem != "swift" || /^ *#/ { next }
        listing && /^      - / { print unquote($2); found[entries]++; next }
        { listing = 0 }
        /^    directory:/ { print unquote($2); found[entries]++; next }
        /^    directories:/ { listing = 1; next }
        END { for (i = 1; i <= entries; i++) if (!found[i]) exit 1 }
    ' .github/dependabot.yml || {
        unread '.github/dependabot.yml: a swift entry names no directory this reads'
        return 1
    }
}

# reported_resolved_files — every tracked Package.resolved but those in a
# directory Dependabot's swift ecosystem updates.
reported_resolved_files() {
    local covered file dir pattern skip
    covered=$(dependabot_swift_directories) || return 1
    while IFS= read -r file; do
        dir=/$(dirname "$file")
        skip=''
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            [ "$pattern" = / ] || pattern=${pattern%/}
            # shellcheck disable=SC2254 # Dependabot's own glob
            case "$dir" in $pattern) skip=1 ;; esac
        done <<<"$covered"
        [ -n "$skip" ] || printf '%s\n' "$file"
    done < <(git ls-files '*Package.resolved')
}

# resolved_pins <Package.resolved> — each pin as
# `<identity><TAB><location><TAB><version>`, the version empty for a pin to a
# revision. Fails on a file this cannot read.
resolved_pins() {
    jq -r 'if (.pins | type) == "array" then .pins[] | [.identity, (.location // ""), (.state.version // "")] | @tsv
        else error("no pins array") end' "$1" || {
        unread "$1: not a Package.resolved this reads"
        return 1
    }
}

# requirements <Package.resolved> <identity> — the requirements on the package
# in the manifests resolved into that file: the manifest beside it, or with
# none beside it, the Xcode workspace's, every top-level package's
# (Tools/lib/package-pins.sh). One `<manifest><TAB><lower><TAB><upper><TAB><closed>`
# line each. A package is named by its URL's last path component, `.git`
# dropped, in any case: SwiftPM's identity. Fails, naming it, on a
# requirement whose form this does not read.
requirements() {
    local resolved=$1 identity=$2 manifest found status=0
    while IFS= read -r manifest; do
        if ! found=$(perl -e '
            my $identity = lc shift;
            local $/;
            my $text = <STDIN>;
            $text =~ s{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse;
            my $v = qr/"(\d+)(?:\.(\d+))?(?:\.(\d+))?"/;
            sub release { join ".", map { $_ // 0 } @_ }
            my $status = 0;
            while ($text =~ m{\.package\s*\(\s*(?:name\s*:\s*"[^"]*"\s*,\s*)?url\s*:\s*"([^"]+)"\s*,\s*((?:[^()]|\([^()]*\))*)\)}g) {
                my ($url, $requirement) = (lc $1, $2);
                $url =~ s{.*/}{};
                $url =~ s{\.git$}{};
                next unless $url eq $identity;
                if ($requirement =~ m{\A(?:from\s*:|\.upToNextMajor\s*\(\s*from\s*:)\s*$v}) {
                    printf "%s\t%d.0.0\t0\n", release($1, $2, $3), $1 + 1;
                } elsif ($requirement =~ m{\A\.upToNextMinor\s*\(\s*from\s*:\s*$v}) {
                    printf "%s\t%d.%d.0\t0\n", release($1, $2, $3), $1, ($2 // 0) + 1;
                } elsif ($requirement =~ m{\A(?:exact\s*:|\.exact\s*\()\s*$v}) {
                    my $exact = release($1, $2, $3);
                    print "$exact\t$exact\t1\n";
                } elsif ($requirement =~ m{\A$v\s*\.\.([.<])\s*$v}) {
                    printf "%s\t%s\t%d\n", release($1, $2, $3), release($5, $6, $7), $4 eq "." ? 1 : 0;
                } else {
                    $requirement =~ s/\s+/ /g;
                    print STDERR "$requirement\n";
                    $status = 1;
                }
            }
            exit $status;
        ' "$identity" <"$manifest" 2>"$scratch/unread"); then
            unread "$manifest: requires $identity as '$(head -1 "$scratch/unread")', a form this does not read"
            status=1
            continue
        fi
        [ -z "$found" ] || awk -v manifest="$manifest" '{ print manifest "\t" $0 }' <<<"$found"
    done < <(if [ -f "$(dirname "$resolved")/Package.swift" ]; then
        printf '%s\n' "$(dirname "$resolved")/Package.swift"
    else
        git ls-files '*/Package.swift' | awk -F/ 'NF == 2'
    fi)
    return "$status"
}

# package_after_move <identity> — what else a move of that package takes.
package_after_move() {
    case "$1" in
        # The Swift generated from each schema is checked in beside it, by
        # the protoc-gen-swift of the pinned revision.
        swift-protobuf) printf ' Then regenerate the checked-in Swift with `Tools/check-generated-protos.sh --write`.' ;;
    esac
}

# package_rows <Package.resolved> <identity> <location> <pinned> <tags> <requirements>
# — report_pin's rows for a package: the newest release its requirements
# admit, which raising a lower bound resolves to, and the newest they exclude,
# which widening every requirement that excludes it resolves to. With no
# requirement here, the newest release. Fails, naming it, on a pin its own
# requirements exclude.
package_rows() {
    local file=$1 identity=$2 location=$3 pinned=$4 tags=$5 required=$6 after newest in_range level manifest lower upper closed
    local manifests=()
    after=$(package_after_move "$identity")
    newest=$(newest_release <<<"$tags")
    if [ -z "$required" ]; then
        level=$(release_level "$pinned" "$newest")
        [ -z "$level" ] || printf '%s\t%s\t%s\t%s\n' "$level" "$newest" "$(release_notes "$location" "$newest")" \
            "No manifest here requires it: deleting \`$file\` and running \`make resolve-packages\` resolves every pin there afresh, this one to the newest release the packages requiring it admit.$after"
        return 0
    fi
    in_range=$tags
    while IFS=$'\t' read -r _ lower upper closed; do
        in_range=$(admitted "$lower" "$upper" "$closed" <<<"$in_range")
    done <<<"$required"
    if ! has_release "$pinned" <<<"$in_range"; then
        unread "$file: $identity is pinned to $pinned, which its requirements exclude"
        return 1
    fi
    in_range=$(newest_release <<<"$in_range")
    level=$(release_level "$pinned" "$in_range")
    if [ -n "$level" ]; then
        while IFS= read -r manifest; do manifests+=("$manifest"); done < <(cut -f1 <<<"$required" | sort -u)
        printf '%s\t%s\t%s\t%s\n' "$level" "$in_range" "$(release_notes "$location" "$in_range")" \
            "Raise its requirement's lower bound to \`$in_range\` in $(code_list or "${manifests[@]}"), then run \`make resolve-packages\`.$after"
    fi
    if [ -n "$(release_level "$in_range" "$newest")" ]; then
        manifests=()
        while IFS= read -r manifest; do manifests+=("$manifest"); done < <(
            while IFS=$'\t' read -r manifest lower upper closed; do
                [ -n "$(admitted "$lower" "$upper" "$closed" <<<"$newest")" ] || printf '%s\n' "$manifest"
            done <<<"$required" | sort -u)
        printf '%s\t%s\t%s\t%s\n' "$(release_level "$pinned" "$newest")" "$newest" "$(release_notes "$location" "$newest")" \
            "Change its requirement to admit \`$newest\` in $(code_list and "${manifests[@]}"), then run \`make resolve-packages\`.$after"
    fi
}

# ---- the report ------------------------------------------------------------------

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

# ---- Swift -----------------------------------------------------------------------

# swift_syntax_moves <major> <minor> — swift-syntax's major names the Swift
# release it parses, so a Swift release in another minor moves it in every
# manifest that requires it.
swift_syntax_moves() {
    local file identity manifests=() manifest
    while IFS= read -r file; do
        while IFS=$'\t' read -r identity _ _; do
            [ "$identity" = swift-syntax ] || continue
            while IFS=$'\t' read -r manifest _; do
                [ -n "$manifest" ] && manifests+=("$manifest")
            done < <(requirements "$file" swift-syntax 2>/dev/null)
        done < <(resolved_pins "$file" 2>/dev/null)
    done < <(git ls-files '*Package.resolved')
    [ "${#manifests[@]}" -gt 0 ] || return 0
    printf ' swift-syntax names the Swift release it parses by its major, so also change its requirement to `from: "%s.0.0"` in %s, then run `make resolve-packages`.' \
        "$(($1 * 100 + $2))" "$(code_list and "${manifests[@]}")"
}

if pinned=$(pinned_swift_version); then
    names=''
    if ! feed=$(curl -fsS --max-time 60 "$swift_feed") || ! names=$(jq -r '.[].name' <<<"$feed" | grep -E "$release_pattern") ||
        ! has_release "$pinned" <<<"$names"; then
        unread "$swift_feed could not be read, or lists no release $pinned, the pinned one"
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
    unread '.swift-version could not be read'
    failed=$((failed + 1))
fi

# ---- Periphery -------------------------------------------------------------------

if ! pinned=$(Tools/install-periphery.sh --version) || ! tags=$(release_tags "$periphery_repository" "$pinned"); then
    failed=$((failed + 1))
else
    rows=$(newer_releases "$pinned" <<<"$tags" | while read -r level release; do
        printf '%s\t%s\t%s\t%s\n' "$level" "$release" "$(release_notes "$periphery_repository" "$release")" \
            "Set \`PERIPHERY_VERSION='$release'\` in \`Tools/install-periphery.sh\`."
    done)
    report_pin Periphery "$pinned" Tools/install-periphery.sh "$rows"
fi

# ---- Package.resolved ------------------------------------------------------------

if files=$(reported_resolved_files); then
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        pins=$(resolved_pins "$file") || { failed=$((failed + 1)); continue; }
        while IFS=$'\t' read -r identity location pinned; do
            [ -n "$identity" ] || continue
            if ! tags=$(release_tags "$location" "$pinned") || ! required=$(requirements "$file" "$identity") ||
                ! rows=$(package_rows "$file" "$identity" "$location" "$pinned" "$tags" "$required"); then
                failed=$((failed + 1))
                continue
            fi
            report_pin "$identity" "$pinned" "$file" "$rows"
        done <<<"$pins"
    done <<<"$files"
else
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
