#!/usr/bin/env bash
# Generates and installs the Ubuntu 24.04 aarch64 SDK for the swift.org
# toolchain .swift-version pins, which the Linux half of `make dead-code`
# cross-builds KernovaKit with on a Mac. swift.org publishes no glibc SDK, so it
# is made with swiftlang/swift-sdk-generator at the toolchain's own release
# tag, built with that toolchain, from swift.org's Ubuntu toolchain and
# Ubuntu's packages.
#
# Idempotent: an installed SDK is reported, never regenerated.
#
# Usage: Tools/install-ubuntu-sdk.sh
#   installs what is absent, then prints the SDK's id
#
# Status text goes to stderr: stdout carries the id alone, so callers can read
# it with a command substitution.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"
# shellcheck source=lib/linux-swift.sh
. "$lib_dir/lib/linux-swift.sh"

version="$(pinned_swift_version)"
id="$(ubuntu_sdk_id "$version")"
swiftly="$(Tools/install-swift-toolchain.sh)"

if [ -z "$(ubuntu_sdk_missing "$version")" ]; then
    pass "$id installed" >&2
    printf '%s\n' "$id"
    exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
generator="$tmp_dir/swift-sdk-generator"

detail "Building swift-sdk-generator at swift-$version-RELEASE" >&2
git clone --quiet --depth 1 --branch "swift-$version-RELEASE" \
    https://github.com/swiftlang/swift-sdk-generator.git "$generator" >&2
build=(run swift build "+$version" -c release --package-path "$generator"
    --only-use-versions-from-resolved-file --product swift-sdk-generator)
"$swiftly" "${build[@]}" >&2

# The bundle is written to the generator's Bundles directory.
detail "Generating $id" >&2
(cd "$generator" && "$("$swiftly" "${build[@]}" --show-bin-path)/swift-sdk-generator" make-linux-sdk \
    --swift-version "$version-RELEASE" --distribution-name ubuntu --distribution-version 24.04 \
    --target-arch aarch64 --no-host-toolchain) >&2

"$swiftly" run swift sdk install "$generator/Bundles/$id.artifactbundle" "+$version" \
    --swift-sdks-path "$(swift_sdks_dir)" >&2

pass "$id installed" >&2
value "$(swift_sdks_dir)/$id.artifactbundle" >&2
printf '%s\n' "$id"
