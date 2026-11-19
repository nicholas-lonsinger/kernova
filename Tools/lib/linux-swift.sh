# Running SwiftPM over KernovaKit for a Linux destination with the swift.org
# toolchain .swift-version pins, and the Ubuntu SDK a Mac builds the dead-code
# scan's Linux half with. Sourced, never run, by every script that builds
# KernovaKit for Linux.

# shellcheck shell=bash

# shellcheck source=static-linux-sdk.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/static-linux-sdk.sh"
# shellcheck source=pinned-swift.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pinned-swift.sh"

# ubuntu_sdk_id <swift version>: the id of the glibc SDK for Ubuntu 24.04 on
# aarch64 that Tools/install-ubuntu-sdk.sh generates, the system the Linux CI
# jobs build in (the swift:<version>-noble image).
ubuntu_sdk_id() {
    printf '%s-RELEASE_ubuntu_noble_aarch64\n' "$1"
}

# ubuntu_sdk_missing <swift version>: on macOS, prints the first piece of what
# the Ubuntu SDK builds with that is not installed, and nothing when all of it is.
ubuntu_sdk_missing() {
    local missing
    missing="$(swiftly_toolchain_missing "$1")"
    if [ -n "$missing" ]; then
        echo "$missing"
    elif [ ! -d "$(swift_sdks_dir)/$(ubuntu_sdk_id "$1").artifactbundle" ]; then
        ubuntu_sdk_id "$1"
    fi
}

# stale_kernova_sdks <swift version>: on macOS, the id of every installed SDK of
# a kind these libraries install — the Static Linux SDK and the Ubuntu SDK —
# that is not the one for that version, one per line. Another checkout may pin
# another version and still build with its SDK, so they are listed, never removed.
stale_kernova_sdks() {
    local version=$1 bundle id
    for bundle in "$(swift_sdks_dir)"/swift-*-RELEASE_static-linux-*.artifactbundle \
        "$(swift_sdks_dir)"/*-RELEASE_ubuntu_noble_aarch64.artifactbundle; do
        [ -d "$bundle" ] || continue
        id="$(basename "$bundle" .artifactbundle)"
        [ "$id" = "$(static_sdk_id "$version")" ] || [ "$id" = "$(ubuntu_sdk_id "$version")" ] || echo "$id"
    done
}

# linux_swift <build|package> <argument>...: runs that SwiftPM command over
# KernovaKit through pinned_swift with the pinned toolchain. The arguments name
# the destination's SDK.
#
# On macOS the toolchain is swiftly's, run with the environment scrubbed so
# Xcode's SDKROOT, TOOLCHAINS and DEVELOPER_DIR cannot reach it, and with
# KERNOVA_PORTABLE_ONLY set, so the manifest declares what it declares on Linux.
# On Linux it is the `swift` on PATH.
linux_swift() {
    local command=$1
    shift
    local swift=(swift "$command")
    if [ "$(uname -s)" = Darwin ]; then
        swift=(env -i "HOME=$HOME" PATH=/usr/bin:/bin KERNOVA_PORTABLE_ONLY=1)
        [ -z "${SWIFTLY_HOME_DIR:-}" ] || swift+=("SWIFTLY_HOME_DIR=$SWIFTLY_HOME_DIR")
        swift+=("$(swiftly_binary)" run swift "$command" "+$(pinned_swift_version)" --swift-sdks-path "$(swift_sdks_dir)")
    fi
    pinned_swift "$(dirname "${BASH_SOURCE[0]}")/../../KernovaKit" "${swift[@]}" -- "$@"
}
