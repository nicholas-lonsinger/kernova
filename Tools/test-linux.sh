#!/usr/bin/env bash
# Runs KernovaKit's Linux tests over a tree on this Mac, in Apple's container:
# what `Tools/attest.sh record test-linux` runs for `make test-linux`, given
# the content tree. Tools/lib/linux-tests.sh says what a run reads, and which
# images this Mac keeps.
#
#     Tools/test-linux.sh <tree-ish>
#
# Exits 0 when the tests pass, 1 when they ran and failed, and 3, naming what
# is missing, when they cannot run here: container absent or its service not
# starting, no hypervisor, or no image for the tree's recipe. Starts
# container's service when it is not running, and builds the image when this
# Mac lacks it.
#
# The run holds its image under a tag of its own, deleted when the script
# exits, so another session deleting the recipe's image cannot take it from a
# run that has it.

set -uo pipefail

[ $# -eq 1 ] || { echo 'usage: Tools/test-linux.sh <tree-ish>' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/linux-tests.sh
. Tools/lib/linux-tests.sh

cannot_run() { echo "test-linux: the Linux tests need $1" >&2; exit 3; }

tree=$1
missing=$(linux_tests_container_up) || cannot_run "$missing"
missing=$(linux_tests_container_image "$tree") || cannot_run "$missing"
image=$(linux_tests_image "$tree") || cannot_run "a recipe for their image in $tree"

held="kernova-linux-tests-run:$(date +%s)-$$-$RANDOM"
trap 'container image delete --force "$held" >/dev/null 2>&1' EXIT
container image tag "$image" "$held" >/dev/null 2>&1 ||
    cannot_run "their image $image, which another session deleted before this run could hold it"

linux_tests_run container "$tree" "$held" --cpus 4 --memory 4g --progress none || exit 1
