# Running SwiftPM over KernovaKit for a Linux destination with the swift.org
# toolchain .swift-version pins, and the Ubuntu SDK a Mac builds the dead-code
# scan's Linux half with. Sourced, never run, by every script that builds
# KernovaKit for Linux.

# shellcheck shell=bash

# shellcheck source=static-linux-sdk.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/static-linux-sdk.sh"
# shellcheck source=package-pins.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/package-pins.sh"

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

# pinned_swift <argument>...: runs `swift <argument>...` with the toolchain
# .swift-version pins. On macOS that is swiftly's, run with the environment
# scrubbed so Xcode's SDKROOT, TOOLCHAINS and DEVELOPER_DIR cannot reach it,
# and with KERNOVA_PORTABLE_ONLY set, so KernovaKit's manifest declares what it
# declares on Linux. On Linux it is the `swift` on PATH.
pinned_swift() {
    if [ "$(uname -s)" = Darwin ]; then
        local run=(env -i "HOME=$HOME" PATH=/usr/bin:/bin KERNOVA_PORTABLE_ONLY=1)
        [ -z "${SWIFTLY_HOME_DIR:-}" ] || run+=("SWIFTLY_HOME_DIR=$SWIFTLY_HOME_DIR")
        "${run[@]}" "$(swiftly_binary)" run swift "$1" "+$(pinned_swift_version)" "${@:2}"
    else
        swift "$@"
    fi
}

# linux_swift <build|package> <argument>...: runs that SwiftPM command over
# KernovaKit with pinned_swift, its dependencies held to the tracked pins by
# with_package_pins. The arguments name the destination's SDK.
linux_swift() {
    local swift=(pinned_swift "$1")
    shift
    [ "$(uname -s)" != Darwin ] || swift+=(--swift-sdks-path "$(swift_sdks_dir)")
    with_package_pins "$(dirname "${BASH_SOURCE[0]}")/../../KernovaKit" "${swift[@]}" -- "$@"
}
