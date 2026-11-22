# Every SwiftPM call on one of this repository's packages, on every platform,
# so each builds exactly the tracked pins and fails rather than re-resolve.
# Sourced, never run:
#
#     . Tools/lib/package-pins.sh
#     with_package_pins KernovaKit swift build --
#
# A top-level package is a peer in Kernova.xcodeproj
# (Tools/check-package-reference.sh), so its pins are the workspace's
# Package.resolved, the file Xcode builds the app against; SwiftPM reads a
# package's pins from beside its manifest, so that file is copied there. Any
# other package tracks its own Package.resolved beside its manifest.

# shellcheck shell=bash

# with_package_pins <package dir> <swift command>... -- [<argument>...]: runs
# `<swift command>... --package-path <package dir>
# --only-use-versions-from-resolved-file <argument>...`, where <swift command>
# runs a SwiftPM subcommand, e.g. `xcrun swift test`, with KERNOVA_SOURCE_ROOT
# naming the checkout to the tests it runs (KernovaPortableTestSupport's
# SourceTree).
with_package_pins() {
    local package repo invocation=()
    package="$(cd "$1" && pwd -P)" || return
    shift
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        invocation+=("$1")
        shift
    done
    if [ $# -eq 0 ]; then
        echo "with_package_pins: no -- after the swift command" >&2
        return 2
    fi
    shift
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    if [ "$(dirname "$package")" = "$repo" ]; then
        local pins="$repo/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        cmp -s "$pins" "$package/Package.resolved" || cp "$pins" "$package/Package.resolved" || return
    fi
    KERNOVA_SOURCE_ROOT=$repo "${invocation[@]}" --package-path "$package" --only-use-versions-from-resolved-file "$@"
}
