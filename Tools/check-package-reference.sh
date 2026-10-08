#!/usr/bin/env bash
# How Kernova.xcodeproj takes KernovaKit in. Two rules:
#
# KernovaKit is a top-level peer in Kernova.xcodeproj — a PBXFileReference in
# the project's main group — and never an XCLocalSwiftPackageReference under
# Package Dependencies. Kernova.xctestplan lists KernovaKitTests from
# `container:KernovaKit`, which the dependency form does not offer the plan:
# Xcode treats a package added that way as upstream and hides its test targets
# from the test-plan picker. Re-adding the package means dragging the folder
# into the Project Navigator from Finder, not Add Package Dependencies → Add
# Local, which is Xcode's default route and silently costs the package's tests.
#
# A test bundle hosted by the app (its target xcconfig sets TEST_HOST) links no
# package product: its package code is the host's, reached through
# BUNDLE_LOADER, and the test-support sources it needs compile into the bundle.
# A product the bundle links puts a second copy of package targets the host
# already links into the test process, and Xcode resolves that diamond by
# building those targets as frameworks under PackageFrameworks/ — in test
# builds only. Each such module then has two locations in one Products
# directory, and `-I Products/<config>` puts the static build's copy ahead of
# the framework's, so a test build compiles against whatever a non-test build
# last left there.
#
# Scoped to KernovaKit by name: a second local package that is legitimately a
# dependency needs the first rule narrowed to KernovaKit's own reference. A
# remote XCRemoteSwiftPackageReference is untouched.
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

# Each native target as "<name>\t<package products it links, space-separated>".
linked_products=$(awk '
    /^\t\t\tisa = PBXNativeTarget;$/ { in_target = 1; name = ""; products = ""; next }
    !in_target { next }
    /^\t\t\};$/ { print name "\t" products; in_target = 0; next }
    /^\t\t\tpackageProductDependencies = \($/ { in_products = 1; next }
    in_products && /^\t\t\t\);$/ { in_products = 0; next }
    in_products {
        product = $0
        sub(/^[^*]*\/\* /, "", product)
        sub(/ \*\/.*$/, "", product)
        products = products (products == "" ? "" : " ") product
        next
    }
    /^\t\t\tname = / {
        name = $0
        sub(/^\t\t\tname = /, "", name)
        sub(/;$/, "", name)
        gsub(/"/, "", name)
    }
' "$pbxproj")

hosted_found=0
for xcconfig in Config/Targets/*.xcconfig; do
    grep -qE '^TEST_HOST[[:space:]]*=' "$xcconfig" || continue
    target=$(basename "$xcconfig" .xcconfig)
    hosted_found=1
    entry=$(printf '%s\n' "$linked_products" | awk -F '\t' -v t="$target" '$1 == t')
    if [ -z "$entry" ]; then
        violation "$xcconfig sets TEST_HOST, but $pbxproj has no native target named $target"
        continue
    fi
    products=${entry#*$'\t'}
    if [ -n "$products" ]; then
        violation "$target is hosted by the app (TEST_HOST) yet links package products: $products — remove them from its Frameworks phase; the host already links the package code, and test-support sources compile into the bundle"
    fi
done

if [ "$hosted_found" -eq 0 ]; then
    violation "no Config/Targets/*.xcconfig sets TEST_HOST — the hosted-bundle rule matched nothing to check"
fi

if [ -n "$violations" ]; then
    echo "check-package-reference: $pbxproj breaks how the project takes KernovaKit in:" >&2
    printf '%s' "$violations" >&2
    exit 1
fi

pass "package reference: KernovaKit is a top-level peer, and no app-hosted test bundle links a package product"
