#!/usr/bin/env bash
# Every local package — a top-level directory holding a Package.swift — is a
# top-level peer in Kernova.xcodeproj: a PBXFileReference in the project's main
# group, and never an XCLocalSwiftPackageReference under Package Dependencies.
# Kernova.xctestplan lists each package's tests from `container:<Package>`,
# which the dependency form does not offer the plan: Xcode treats a package
# added that way as upstream and hides its test targets from the test-plan
# picker. Re-adding a package means dragging its folder into the Project
# Navigator from Finder, not Add Package Dependencies → Add Local, which is
# Xcode's default route and silently costs the package's tests.
#
# A remote XCRemoteSwiftPackageReference is untouched.
#
# No project target takes KernovaKit's `KernovaTestSupport` product; the
# project's test bundles compile its folder instead. Linked into the app-hosted
# KernovaTests, the product puts a second KernovaKit in the test process: Xcode
# then builds KernovaKit as a framework in test builds only, and
# `-I Products/<config>` resolves the stale static module ahead of it.
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

packages=$(git ls-files '*/Package.swift' | awk -F/ 'NF == 2 { print $1 }')

if [ -z "$packages" ]; then
    echo "check-package-reference: no tracked top-level Package.swift" >&2
    exit 1
fi

violations=""
violation() { violations="$violations  $1"$'\n'; }

if grep -q 'isa = XCLocalSwiftPackageReference;' "$pbxproj"; then
    violation "an XCLocalSwiftPackageReference is present — drag the package folder into the Project Navigator instead of adding it as a local package"
fi

for package in $packages; do
    if ! grep -qE "\{isa = PBXFileReference;.*[[:space:]]path = $package;" "$pbxproj"; then
        violation "no PBXFileReference with path = $package — the package is not a top-level peer, so Kernova.xctestplan cannot reach its tests"
    fi
done

if grep -qE '^[[:space:]]*productName = KernovaTestSupport;' "$pbxproj"; then
    violation "a target takes the KernovaTestSupport product — add KernovaKit/Sources/KernovaTestSupport to the target's synchronized folders instead"
fi

if [ -n "$violations" ]; then
    echo "check-package-reference: $pbxproj breaks a package-linking rule:" >&2
    printf '%s' "$violations" >&2
    exit 1
fi

pass "package references: $(echo "$packages" | paste -sd ' ' -) are top-level peers, not package dependencies, and no project target takes KernovaTestSupport"
