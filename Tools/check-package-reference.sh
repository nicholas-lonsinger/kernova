#!/usr/bin/env bash
# KernovaKit is a top-level peer in Kernova.xcodeproj — a PBXFileReference in
# the project's main group — and never an XCLocalSwiftPackageReference under
# Package Dependencies. Kernova.xctestplan lists KernovaKitTests from
# `container:KernovaKit`, which the dependency form does not offer the plan:
# Xcode treats a package added that way as upstream and hides its test targets
# from the test-plan picker. Re-adding the package means dragging the folder
# into the Project Navigator from Finder, not Add Package Dependencies → Add
# Local, which is Xcode's default route and silently costs the package's tests.
#
# Scoped to KernovaKit by name: a second local package that is legitimately a
# dependency needs this check narrowed to KernovaKit's own reference. A remote
# XCRemoteSwiftPackageReference is untouched.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

pbxproj="Kernova.xcodeproj/project.pbxproj"

if [ ! -f "$pbxproj" ]; then
    echo "check-package-reference: $pbxproj is missing" >&2
    exit 1
fi

violations=""
violation() { violations="$violations  $1"$'\n'; }

if grep -q 'isa = XCLocalSwiftPackageReference;' "$pbxproj"; then
    violation "an XCLocalSwiftPackageReference is present — drag KernovaKit into the Project Navigator instead of adding it as a local package"
fi

if ! grep -qE '\{isa = PBXFileReference;.*[[:space:]]path = KernovaKit;' "$pbxproj"; then
    violation "no PBXFileReference with path = KernovaKit — the package is no longer a top-level peer, so Kernova.xctestplan cannot reach KernovaKitTests"
fi

if [ -n "$violations" ]; then
    echo "check-package-reference: $pbxproj no longer holds KernovaKit as a peer folder:" >&2
    printf '%s' "$violations" >&2
    exit 1
fi

pass "package reference: KernovaKit is a top-level peer, not a package dependency"
