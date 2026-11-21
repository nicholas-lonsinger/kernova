#!/usr/bin/env bash
# Fixture tests for Tools/check-package-origins.sh: which package references it
# flags in each source, on which line, and which forms it refuses to skip.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-package-origins.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

manifest='KernovaKit/Package.swift'
resolved='Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
project='Kernova.xcodeproj/project.pbxproj'

# expect <name> <path> <want> <contents> — the check, run over a file at <path>
# holding <contents>, flags exactly the lines in <want> (space-separated, empty
# for a pass).
expect() {
    local name=$1 path=$2 want=$3 dir="$tmp/$1" output status got
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$4" >"$dir/$path"
    output=$(cd "$dir" && bash "$check_script" "$path" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-package-origins: $path:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

# Package.swift.

expect allowed-orgs "$manifest" '' 'dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.0"),
    .package(
        url: "https://github.com/swift-server/swift-service-lifecycle", .upToNextMajor(from: "2.0.0")),
    .package(name: "Apple", url: "git@github.com:Apple/swift-log.git", from: "1.0.0"),
    .package(path: "../KernovaKit"),
]'
expect other-org "$manifest" '2 4' 'dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    .package(
        url: "https://github.com/apple-forks/swift-protobuf.git", from: "1.39.0"),
]'
expect other-host "$manifest" '1 2' '.package(url: "https://gitlab.com/apple/swift-protobuf.git", from: "1.0.0")
.package(url: "https://github.com.evil.example/apple/swift-protobuf.git", from: "1.0.0")'
expect registry "$manifest" '1' '.package(id: "apple.swift-protobuf", from: "1.0.0")'
expect unread-form "$manifest" '1' '.package(url: protobufURL, from: "1.0.0")'
expect comments "$manifest" '' '// .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.0.0"),
/* .package(url: "https://github.com/pointfreeco/swift-snapshot-testing") */
.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0")  // not pointfreeco'

# Package.resolved — every pin, transitive ones included.

expect resolved-allowed "$resolved" '' '{
  "pins" : [
    {
      "identity" : "swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-protobuf.git",
      "state" : { "version" : "1.39.0" }
    }
  ],
  "version" : 3
}'
expect resolved-transitive "$resolved" '12' '{
  "pins" : [
    {
      "identity" : "swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-protobuf.git",
      "state" : { "version" : "1.39.0" }
    },
    {
      "identity" : "xctest-dynamic-overlay",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/pointfreeco/xctest-dynamic-overlay",
      "state" : { "version" : "1.0.0" }
    }
  ],
  "version" : 3
}'
expect resolved-unread-pin "$resolved" '1' '{
  "pins" : [
    {
      "identity" : "swift-protobuf",
      "repositoryURL" : "https://github.com/pointfreeco/swift-protobuf.git"
    }
  ]
}'

# project.pbxproj.

expect project-allowed "$project" '' '		0A1B2C3D /* XCRemoteSwiftPackageReference "swift-protobuf" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/apple/swift-protobuf.git";
		};'
expect project-other-org "$project" '3' '		0A1B2C3D /* XCRemoteSwiftPackageReference "swift-dependencies" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/pointfreeco/swift-dependencies";
		};'
expect project-unread-reference "$project" '1' '		0A1B2C3D /* XCRemoteSwiftPackageReference "swift-dependencies" */ = {
			isa = XCRemoteSwiftPackageReference;
		};'
expect project-local-only "$project" '' '		0A1B2C3D /* KernovaKit */ = {isa = PBXFileReference; lastKnownFileType = wrapper; path = KernovaKit; sourceTree = "<group>"; };'

# An unreadable file fails.

output=$(cd "$tmp" && bash "$check_script" "$manifest" 2>&1)
status=$?
if [ "$status" -eq 0 ] || [[ $output != *"cannot read $manifest"* ]]; then
    fail "missing-file: exited $status without naming the unread file"
fi

if [ "$FAIL" -gt 0 ]; then
    printf '%d check-package-origins fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'check-package-origins fixtures: all passed\n'
