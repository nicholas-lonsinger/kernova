#!/usr/bin/env bash
# Runs KernovaKit's Linux tests over a tree on this Mac, in Apple's container:
# what `Tools/attest.sh record test-linux` runs for `make test-linux`, given
# the content tree. Exits with the tests' status. Tools/lib/linux-tests.sh
# says what a run reads.
#
#     Tools/test-linux.sh <tree-ish>
#
# Starts container's service when it is not running. When this Mac has no
# image for the tree's recipe it builds one, then deletes every other
# kernova-linux-tests image, and the base image when the build pulled it, so
# the store keeps one recipe's image. Deleting an image another session's run
# is using is safe: container 1.7.1 keeps a running container running when
# its image is deleted.

set -uo pipefail

[ $# -eq 1 ] || { echo 'usage: Tools/test-linux.sh <tree-ish>' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/linux-tests.sh
. Tools/lib/linux-tests.sh

die() { echo "test-linux: $1" >&2; exit 1; }

tree=$1
{ image=$(linux_tests_image "$tree") && base=$(linux_tests_base "$tree"); } ||
    die "$tree holds no recipe for the image: Tools/linux-tests.Containerfile and .swift-version"
missing=$(linux_tests_container_up) || die "the Linux tests need $missing"

if ! container image inspect "$image" >/dev/null 2>&1; then
    pulled_base=true
    container image inspect "$base" >/dev/null 2>&1 && pulled_base=false
    echo "test-linux: building $image on $base" >&2
    linux_tests_build_image container "$tree" --platform linux/arm64 --progress plain >&2 ||
        die "building $image failed"
    stale=()
    while IFS= read -r other; do
        case "$other" in kernova-linux-tests:*) [ "$other" = "$image" ] || stale+=("$other") ;; esac
    done < <(container image list -q)
    [ "$pulled_base" = false ] || stale+=("$base")
    if [ "${#stale[@]}" -gt 0 ]; then
        container image delete "${stale[@]}" >&2 || echo "test-linux: could not delete every one of ${stale[*]}" >&2
    fi
fi

linux_tests_run container "$tree" --cpus 4 --memory 4g --progress none
