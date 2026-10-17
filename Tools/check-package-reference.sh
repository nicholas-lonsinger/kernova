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
# A hosted test process holds one copy of each package product, so a test
# bundle and the app its TEST_HOST names never both link package products: the
# products are static, and each image linking one carries its own copy, so the
# process would hold two sets of type metadata and two
# `KernovaLogger.forwardingSink`s. A bundle with a BUNDLE_LOADER reaches the
# code through its host; one without links the code itself, and its host links
# none. The pairs come from each test target's xcconfig, and a link is either
# a packageProductDependencies entry or a package product in the Frameworks
# phase.
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

# One line per native target: name, product path, xcconfig file name, and how
# many package products it links (dependencies plus Frameworks-phase entries).
targets=$(awk '
    /^\t\t[0-9A-Fa-f]+ \/\* .* \*\/ = \{isa = PBXBuildFile;.*productRef = / { package_file[$1] = 1; next }
    /^\t\t[0-9A-Fa-f]+ \/\* .* \*\/ = \{isa = PBXFileReference;/ {
        if (match($0, /[[:space:]]path = [^;]*;/)) {
            path = substr($0, RSTART + 8, RLENGTH - 9)
            gsub(/"/, "", path)
            file_path[$1] = path
        }
        next
    }
    /^\t\t[0-9A-Fa-f]+ \/\* .* \*\/ = \{$/ || /^\t\t[0-9A-Fa-f]+ = \{$/ { id = $1; isa = ""; list = ""; next }
    /^\t\t\tisa = / { isa = $3; sub(/;$/, "", isa); if (isa == "PBXNativeTarget") targets[++count] = id; next }
    /^\t\t\t[A-Za-z]+ = \($/ { list = $1; next }
    /^\t\t\t\);$/ { list = ""; next }
    list != "" && /^\t\t\t\t[0-9A-Fa-f]+/ {
        item = $1
        if (isa == "PBXFrameworksBuildPhase" && list == "files" && (item in package_file)) phase_packages[id]++
        else if (isa == "PBXNativeTarget" && list == "buildPhases") phases[id] = phases[id] " " item
        else if (isa == "PBXNativeTarget" && list == "packageProductDependencies") links[id]++
        else if (isa == "XCConfigurationList" && list == "buildConfigurations" && !(id in first_config)) first_config[id] = item
        next
    }
    isa == "PBXNativeTarget" && /^\t\t\tname = / { v = $3; sub(/;$/, "", v); gsub(/"/, "", v); name[id] = v; next }
    isa == "PBXNativeTarget" && /^\t\t\tproductReference = / { product[id] = $3; next }
    isa == "PBXNativeTarget" && /^\t\t\tbuildConfigurationList = / { config_list[id] = $3; next }
    isa == "XCBuildConfiguration" && /^\t\t\tbaseConfigurationReference = / { base[id] = $3; next }
    END {
        for (i = 1; i <= count; i++) {
            t = targets[i]
            n = links[t] + 0
            split(phases[t], ids, " ")
            for (j in ids) n += phase_packages[ids[j]]
            printf "%s\t%s\t%s\t%d\n", name[t], file_path[product[t]], file_path[base[first_config[config_list[t]]]], n
        }
    }
' "$pbxproj")

hosted_pairs=0
while IFS=$'\t' read -r bundle bundle_product xcconfig bundle_links; do
    case "$bundle_product" in *.xctest) ;; *) continue ;; esac
    test_host=$(sed -n 's/^[[:space:]]*TEST_HOST[[:space:]]*=[[:space:]]*//p' "Config/Targets/$xcconfig" 2>/dev/null | head -1)
    [ -n "$test_host" ] || continue
    host_product=$(printf '%s\n' "$test_host" | sed -n 's#.*/\([^/]*\.app\)/.*#\1#p')
    host_line=$(awk -F'\t' -v p="$host_product" '$2 == p' <<<"$targets")
    if [ -z "$host_product" ] || [ -z "$host_line" ]; then
        violation "$bundle: TEST_HOST $test_host names no app target in the project"
        continue
    fi
    hosted_pairs=$((hosted_pairs + 1))
    host=$(cut -f1 <<<"$host_line")
    host_links=$(cut -f4 <<<"$host_line")
    if [ "$bundle_links" -gt 0 ] && [ "$host_links" -gt 0 ]; then
        violation "$bundle and its test host $host both link package products — the test process would hold two copies; link them into one of the two"
    fi
done <<<"$targets"

if [ "$hosted_pairs" -eq 0 ]; then
    violation "no test target names a TEST_HOST the project builds — the one-copy rule checked nothing"
fi

if [ -n "$violations" ]; then
    echo "check-package-reference: $pbxproj breaks a package-linking rule:" >&2
    printf '%s' "$violations" >&2
    exit 1
fi

pass "package references: $(echo "$packages" | paste -sd ' ' -) are top-level peers, not package dependencies, no project target takes KernovaTestSupport, and no hosted test bundle links package products alongside its host ($hosted_pairs pairs)"
