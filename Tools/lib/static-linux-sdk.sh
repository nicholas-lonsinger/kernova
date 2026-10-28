# The swift.org toolchain .swift-version pins and the Static Linux SDK built
# for it, which the Linux guest agent cross-builds with: the SDK's pin, its id
# and download, and whether they are installed.
# Sourced, never run, by every script that installs, checks or builds with
# them, and by the Linux CI job.

# shellcheck shell=bash

# The SDK release built for the pinned toolchain, and its checksum from
# https://www.swift.org/api/v1/install/releases.json. Moving .swift-version
# moves these with it; a stale pair fails the checksum rather than installing.
# shellcheck disable=SC2034 # read by the scripts that source this
STATIC_SDK_VERSION=0.1.0
# shellcheck disable=SC2034
STATIC_SDK_CHECKSUM=cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c

# static_sdk_id <swift version>: the SDK's id, which is also its bundle's name.
static_sdk_id() {
    printf 'swift-%s-RELEASE_static-linux-%s\n' "$1" "$STATIC_SDK_VERSION"
}

# static_sdk_url <swift version>: where swift.org publishes the SDK.
static_sdk_url() {
    printf 'https://download.swift.org/swift-%s-release/static-sdk/swift-%s-RELEASE/%s.artifactbundle.tar.gz\n' \
        "$1" "$1" "$(static_sdk_id "$1")"
}

# swiftly_binary: the swiftly that installs and runs the toolchain on macOS.
swiftly_binary() {
    printf '%s/bin/swiftly\n' "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}"
}

# swift_toolchain_missing <swift version>: prints the first piece of what the
# agent builds with that is not installed, and nothing when all of it is. On
# macOS that is swiftly, the toolchain and the SDK; on Linux the toolchain is
# the `swift` on PATH, so only the SDK is looked for.
swift_toolchain_missing() {
    local version=$1 id
    id="$(static_sdk_id "$version")"
    if [ "$(uname -s)" = Darwin ]; then
        if [ ! -x "$(swiftly_binary)" ]; then
            echo swiftly
        elif [ ! -d "$HOME/Library/Developer/Toolchains/swift-${version}-RELEASE.xctoolchain" ]; then
            echo "Swift $version"
        elif [ ! -d "$HOME/Library/org.swift.swiftpm/swift-sdks/${id}.artifactbundle" ]; then
            echo "$id"
        fi
    elif ! swift sdk list 2>/dev/null | grep -qxF "$id"; then
        echo "$id"
    fi
}
