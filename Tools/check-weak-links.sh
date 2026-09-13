#!/usr/bin/env bash
# A framework introduced above the deployment target must be loaded weakly, or
# the app is killed at launch on every OS that does not ship it. The linker
# does this on its own — it reads the framework's own minimum from the SDK and
# emits LC_LOAD_WEAK_DYLIB — so nothing in Config/ asks for it, and that is
# exactly why it is worth asserting: the load command is the only place the
# decision is visible, and a raised floor or a changed linker would flip it
# silently into a launch crash nobody sees until a user on the older OS reports
# one.
#
# Every Mach-O the app bundle ships is scanned, not just the executable: a
# Debug build puts the app's own code in Kernova.debug.dylib and leaves a stub
# behind, so checking the executable alone would find nothing and pass.
# A framework listed here that no image links at all is a failure rather than a
# skip, for the same reason — "nothing to check" is what a broken check says.
#
# Runs against a BUILT product, so it is not part of `make lint` (which never
# builds). CI invokes it after the build step in xcodebuild-test.yml.
#
# Usage:
#   Tools/check-weak-links.sh [<path-to-.app>]
#
# With no argument it resolves the Debug Kernova.app: CI's fixed
# -derivedDataPath when $CI is set, otherwise the arena
# Tools/derived-data-path.sh reports. CONFIGURATION overrides Debug.
#
# Written for bash 3.2, which is what macOS ships: no mapfile, no associative
# arrays.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

# One "<framework>:<macOS version it was introduced in>" per line. A framework
# is only required to be weak while the deployment target is below its own
# floor; at or above it, a hard link is correct.
weak_frameworks="AccessoryAccess:27.0"

configuration="${CONFIGURATION:-Debug}"

resolve_app() {
    if [ -n "${CI:-}" ]; then
        echo "DerivedData/Kernova/Build/Products/$configuration/Kernova.app"
        return
    fi
    local arena
    arena=$(Tools/derived-data-path.sh 2>/dev/null) || return 1
    echo "$arena/Build/Products/$configuration/Kernova.app"
}

app="${1:-}"
if [ -z "$app" ]; then
    app=$(resolve_app) || {
        echo "check-weak-links: could not resolve the build arena" >&2
        exit 1
    }
fi

if [ ! -d "$app" ]; then
    echo "check-weak-links: no built app at $app — build first" >&2
    exit 1
fi

# Every Mach-O the bundle carries, one path per line. Identified by `file`
# rather than a name pattern, so a renamed or newly added image is covered
# without editing this script.
images=$(
    find "$app/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null |
        while IFS= read -r candidate; do
            if file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
                echo "$candidate"
            fi
        done
)

if [ -z "$images" ]; then
    echo "check-weak-links: found no Mach-O images under $app/Contents" >&2
    exit 1
fi

# The floor every project target inherits.
deployment_target=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET = *//p' Config/Base.xcconfig | head -1)
if [ -z "$deployment_target" ]; then
    echo "check-weak-links: MACOSX_DEPLOYMENT_TARGET not found in Config/Base.xcconfig" >&2
    exit 1
fi

# True when $1 < $2, comparing dotted versions.
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# Every load command in image $2 naming framework $1, as bare LC_LOAD_DYLIB /
# LC_LOAD_WEAK_DYLIB lines.
load_kinds_for() {
    otool -l "$2" 2>/dev/null | awk -v fw="/$1.framework/" '
        /^ *cmd LC_LOAD(_WEAK)?_DYLIB$/ { kind = $2 }
        index($0, fw) && /^ *name / { print kind }
    '
}

status=0

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="${entry%%:*}"
    introduced="${entry##*:}"
    linked=0
    hard_linked_in=""

    while IFS= read -r image; do
        [ -n "$image" ] || continue
        while IFS= read -r kind; do
            [ -n "$kind" ] || continue
            linked=1
            if [ "$kind" != "LC_LOAD_WEAK_DYLIB" ]; then
                hard_linked_in="$hard_linked_in    ${image#"$app"/}"$'\n'
            fi
        done <<EOF
$(load_kinds_for "$name" "$image")
EOF
    done <<EOF
$images
EOF

    if [ "$linked" -eq 0 ]; then
        echo "check-weak-links: no image in $app links $name" >&2
        echo "  Either the code using it is gone — drop it from weak_frameworks" >&2
        echo "  in this script — or the link was lost and the feature is dead." >&2
        status=1
        continue
    fi

    if ! version_lt "$deployment_target" "$introduced"; then
        continue
    fi

    if [ -n "$hard_linked_in" ]; then
        echo "check-weak-links: $name is hard-linked (LC_LOAD_DYLIB) in:" >&2
        printf '%s' "$hard_linked_in" >&2
        echo "  It was introduced in macOS $introduced, above the deployment target" >&2
        echo "  $deployment_target, so a hard link crashes the app at launch below it." >&2
        status=1
    fi
done <<EOF
$weak_frameworks
EOF

if [ "$status" -eq 0 ]; then
    echo "  ✓ weak links: frameworks above the deployment target load weakly"
fi
exit "$status"
