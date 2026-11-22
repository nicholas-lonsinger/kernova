#!/usr/bin/env bash
# Installs the `protoc` and `protoc-gen-swift` of the swift-protobuf revision
# the Package.resolved of Kernova.xcodeproj, under the current directory, pins
# — built from a fetch of that revision, never taken from Homebrew or the
# system — into the machine's tool cache (Tools/lib/tool-cache.sh), and prints
# protoc's path; protoc-gen-swift is beside it.
#
# Usage: Tools/install-protoc.sh [--path]
#   --path  print protoc's path, installing nothing
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.
#
# pin: none — builds the swift-protobuf revision Package.resolved pins

set -euo pipefail

# A git hook exports GIT_DIR and its companions to its children (githooks(5)),
# and GIT_DIR outranks `-C` and the scratch checkout's own .git, so under
# `pre-push` the git and SwiftPM calls below would act on the repository being
# pushed.
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/tool-cache.sh
. "$root/Tools/lib/tool-cache.sh"

resolved=Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [ ! -f "$resolved" ]; then
    echo "install-protoc.sh: no $resolved under $PWD — run it from the repository root" >&2
    exit 1
fi
# The `revision` that follows the swift-protobuf pin's `identity` line.
revision=$(awk -F'"' '/"identity"/ { pin = $4 } pin == "swift-protobuf" && /"revision"/ { print $4; exit }' "$resolved")
if [ -z "$revision" ]; then
    echo "install-protoc.sh: $resolved pins no swift-protobuf revision" >&2
    exit 1
fi
inputs=(swift-protobuf "$revision" -- Tools/install-protoc.sh)

build_protoc() {
    local entry=$1 source=$2/swift-protobuf product built build_log
    git init -q "$source"
    if ! git -C "$source" fetch -q --depth 1 https://github.com/apple/swift-protobuf.git "$revision" ||
        ! git -C "$source" checkout -q FETCH_HEAD; then
        echo "install-protoc.sh: could not fetch swift-protobuf $revision" >&2
        return 1
    fi
    for product in protoc protoc-gen-swift; do
        if ! build_log=$(swift build -c release --package-path "$source" --product "$product" 2>&1); then
            printf '%s\n' "$build_log" >&2
            echo "install-protoc.sh: building $product from swift-protobuf $revision failed" >&2
            return 1
        fi
    done
    built=$(swift build -c release --package-path "$source" --show-bin-path)
    cp "$built/protoc" "$built/protoc-gen-swift" "$entry/"
}

verify_protoc() {
    "$1/protoc" --version >/dev/null && "$1/protoc-gen-swift" --version >/dev/null
}

case "${1:-}" in
    '') dir=$(tool_install build_protoc verify_protoc "${inputs[@]}") ;;
    --path) dir=$(tool_dir "${inputs[@]}") ;;
    *)
        echo 'usage: Tools/install-protoc.sh [--path]' >&2
        exit 2
        ;;
esac
printf '%s\n' "$dir/protoc"
