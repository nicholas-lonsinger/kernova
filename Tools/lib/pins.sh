# The versions this repository pins to an upstream release, and where each is
# declared, for Tools/outdated-pins.sh, which compares them with upstream, and
# Tools/check-pins.sh, which checks every declaration reads. Sourced, never
# run; run from the repository root.
#
# A pin is one of:
#
# - the swift.org release .swift-version names; Tools/lib/static-linux-sdk.sh
#   holds the Static Linux SDK built for it.
# - a tag an installer names. Each tracked Tools/install-*.sh declares, in the
#   comment block it opens with, either
#
#       # pin: git <repository URL> <variable>
#
#   when <variable>, assigned once in it to a literal, names a release tag of
#   that repository, or
#
#       # pin: none — <why>
#
# - a version in a tracked Package.resolved, except in a directory
#   .github/dependabot.yml gives the swift ecosystem, whose pins Dependabot
#   opens pull requests for.

# shellcheck shell=bash

# shellcheck source=static-linux-sdk.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/static-linux-sdk.sh"

# A release: one to three dot-separated numbers, optionally after a `v`. A
# prerelease, or any other tag, is not one.
pins_release_pattern='^v?[0-9]+(\.[0-9]+)?(\.[0-9]+)?$'

pins_error() { printf 'pins: %s\n' "$1" >&2; }

is_release() { printf '%s\n' "$1" | grep -Eq "$pins_release_pattern"; }

# swift_pin — the swift.org release .swift-version names.
swift_pin() {
    local version
    version=$(pinned_swift_version) || return 1
    if ! is_release "$version"; then
        pins_error ".swift-version holds '$version', not a release"
        return 1
    fi
    printf '%s\n' "$version"
}

pins_installers() { git ls-files 'Tools/install-*.sh'; }

# installer_pin <installer> — what it declares: `git<TAB><URL><TAB><variable><TAB><tag>`,
# or `none`. Fails, naming the installer, on a missing or malformed declaration.
installer_pin() {
    local installer=$1 declared kind url variable rest assigned value
    declared=$(awk 'NR == 1 && /^#!/ { next } /^#/ { print; next } { exit }' "$installer" | grep '^# pin:')
    case "$declared" in
        *$'\n'*)
            pins_error "$installer: declares more than one \`# pin:\`"
            return 1
            ;;
        '# pin: none — '?*)
            echo none
            return 0
            ;;
        '')
            pins_error "$installer: the comment block it opens with declares no \`# pin: git <repository URL> <variable>\` or \`# pin: none — <why>\`"
            return 1
            ;;
    esac
    read -r _ _ kind url variable rest <<<"$declared"
    if [ "$kind" != git ] || [ -z "$url" ] || ! [[ $variable =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [ -n "$rest" ]; then
        pins_error "$installer: '$declared' is not \`# pin: git <repository URL> <variable>\` or \`# pin: none — <why>\`"
        return 1
    fi
    assigned=$(grep -E "^$variable=" "$installer")
    case "$assigned" in
        '')
            pins_error "$installer: declares $variable, which it never assigns at the start of a line"
            return 1
            ;;
        *$'\n'*)
            pins_error "$installer: assigns $variable more than once"
            return 1
            ;;
    esac
    value=${assigned#*=}
    value=${value#[\'\"]}
    value=${value%[\'\"]}
    if ! is_release "$value"; then
        pins_error "$installer: $variable is '$value', not a release tag"
        return 1
    fi
    printf 'git\t%s\t%s\t%s\n' "$url" "$variable" "$value"
}

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
        END {
            for (i = 1; i <= entries; i++)
                if (!found[i]) exit 1
        }
    ' .github/dependabot.yml || {
        pins_error '.github/dependabot.yml: a swift entry names no directory this reads'
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
        [ "$dir" != /. ] || dir=/
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

# resolved_pins <Package.resolved> — each pin as `<identity><TAB><location><TAB><version>`.
# Fails on a file this cannot read, or a pin to a revision with no release.
resolved_pins() {
    local pins identity location version status=0
    pins=$(jq -r 'if (.pins | type) == "array" then .pins[] | [.identity, (.location // ""), (.state.version // "")] | @tsv
        else error("no pins array") end' "$1") || {
        pins_error "$1: not a Package.resolved this reads"
        return 1
    }
    while IFS=$'\t' read -r identity location version; do
        [ -n "$identity" ] || continue
        if [ -z "$location" ]; then
            pins_error "$1: $identity has no location"
            status=1
        elif ! is_release "$version"; then
            pins_error "$1: $identity is pinned to ${version:-a revision}, not a release"
            status=1
        else
            printf '%s\t%s\t%s\n' "$identity" "$location" "$version"
        fi
    done <<<"$pins"
    return "$status"
}

# requiring_manifests <Package.resolved> <identity> — the manifests resolved
# into that file whose requirements name the package: the manifest beside it,
# or for one with none beside it, the Xcode workspace's, every top-level
# package's (Tools/lib/package-pins.sh). A package is named by its URL's last
# path component, `.git` dropped, in any case: SwiftPM's identity.
requiring_manifests() {
    local resolved=$1 identity manifest url name
    identity=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r manifest; do
        while IFS= read -r url; do
            name=$(basename "$url" .git | tr '[:upper:]' '[:lower:]')
            if [ "$name" = "$identity" ]; then
                printf '%s\n' "$manifest"
                break
            fi
        done < <(grep -oE 'url: *"[^"]+"' "$manifest" | sed -E 's/^url: *"//; s/"$//')
    done < <(if [ -f "$(dirname "$resolved")/Package.swift" ]; then
        printf '%s\n' "$(dirname "$resolved")/Package.swift"
    else
        git ls-files '*/Package.swift' | awk -F/ 'NF == 2'
    fi)
}

# newer_releases <pinned> — of the versions on stdin, the newest release at
# each level that is newer than <pinned>, one `<level> <version>` line each,
# in this order: `patch`, same major and minor; `minor`, same major; `major`.
# A missing component counts as 0, so 6.4 is 6.4.0.
newer_releases() {
    grep -E "$pins_release_pattern" | awk -v pinned="$1" '
        function parse(v, out,   n, part) {
            sub(/^v/, "", v)
            n = split(v, part, ".")
            out[1] = part[1] + 0; out[2] = (n >= 2 ? part[2] : 0) + 0; out[3] = (n >= 3 ? part[3] : 0) + 0
        }
        function newer(a, b) {
            if (a[1] != b[1]) return a[1] > b[1]
            if (a[2] != b[2]) return a[2] > b[2]
            return a[3] > b[3]
        }
        BEGIN { parse(pinned, p) }
        {
            parse($0, v)
            if (!newer(v, p)) next
            level = v[1] != p[1] ? "major" : v[2] != p[2] ? "minor" : "patch"
            if (level in best) {
                b[1] = best1[level]; b[2] = best2[level]; b[3] = best3[level]
                if (!newer(v, b)) next
            }
            best[level] = $0; best1[level] = v[1]; best2[level] = v[2]; best3[level] = v[3]
        }
        END { if ("patch" in best) print "patch", best["patch"]; if ("minor" in best) print "minor", best["minor"]; if ("major" in best) print "major", best["major"] }
    '
}

# pins_declared — every pin's declaration reads: .swift-version, each
# installer's `# pin:`, and each reported Package.resolved. Reports each that
# does not before failing.
pins_declared() {
    local status=0 installer files file
    swift_pin >/dev/null || status=1
    while IFS= read -r installer; do
        installer_pin "$installer" >/dev/null || status=1
    done < <(pins_installers)
    files=$(reported_resolved_files) || return 1
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        resolved_pins "$file" >/dev/null || status=1
    done <<<"$files"
    return "$status"
}
