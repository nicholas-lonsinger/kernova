#!/usr/bin/env bash
# The Swift generated from each protobuf schema is checked in next to it, so no
# build runs `protoc`: swift-protobuf's build plugin compiles `protoc` from
# source on every host, and that compile fails for Windows arm64 (abseil built
# without NOMINMAX, then a clang backend crash on upb's inline-asm varint
# encoder). This check regenerates every file with the `protoc` and
# `protoc-gen-swift` of the swift-protobuf revision Kernova.xcodeproj's
# Package.resolved pins, and fails on any difference.
#
# The tools are built once per revision from a fetch of that exact revision,
# never taken from Homebrew or the system, and only the two binaries are kept,
# under ~/Library/Caches/Kernova, so CI can save them.
#
# Usage: Tools/check-generated-protos.sh [--write]
#   --write   replaces each generated file with the regenerated one

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# Each schema; its generated file is `<name>.pb.swift` in the same directory,
# which is also the import root.
schemas=(
    KernovaKit/Sources/KernovaKit/Proto/kernova.proto
    KernovaKit/Sources/KernovaWire/Proto/kernova_v2.proto
)
options=(--swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores)

write=0
case "${1:-}" in
    '') ;;
    --write) write=1 ;;
    *)
        echo "usage: $0 [--write]" >&2
        exit 2
        ;;
esac

resolved=Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# The `revision` that follows the swift-protobuf pin's `identity` line.
revision=$(awk -F'"' '/"identity"/ { pin = $4 } pin == "swift-protobuf" && /"revision"/ { print $4; exit }' "$resolved")
if [ -z "$revision" ]; then
    echo "check-generated-protos: $resolved pins no swift-protobuf revision" >&2
    exit 1
fi

bin="$HOME/Library/Caches/Kernova/swift-protobuf/$revision"
if [ ! -x "$bin/protoc" ] || [ ! -x "$bin/protoc-gen-swift" ]; then
    mkdir -p "${bin%/*}" || exit 1
    staging=$(mktemp -d "${bin%/*}/.build.XXXXXX") || exit 1
    trap 'rm -rf "$staging"' EXIT
    if ! { git init -q "$staging/source" &&
        git -C "$staging/source" fetch -q --depth 1 https://github.com/apple/swift-protobuf.git "$revision" &&
        git -C "$staging/source" checkout -q FETCH_HEAD; }; then
        echo "check-generated-protos: could not fetch swift-protobuf $revision" >&2
        exit 1
    fi
    for product in protoc protoc-gen-swift; do
        if ! build_log=$(xcrun swift build -c release --package-path "$staging/source" --product "$product" 2>&1); then
            printf '%s\n' "$build_log" >&2
            echo "check-generated-protos: building $product from swift-protobuf $revision failed" >&2
            exit 1
        fi
    done
    built=$(xcrun swift build -c release --package-path "$staging/source" --show-bin-path) || exit 1
    mkdir -p "$staging/bin" && cp "$built/protoc" "$built/protoc-gen-swift" "$staging/bin/" || exit 1
    # A run that built meanwhile holds the same revision's tools; keep them.
    [ -d "$bin" ] || mv "$staging/bin" "$bin"
    rm -rf "$staging"
    trap - EXIT
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

status=0
for schema in "${schemas[@]}"; do
    dir=${schema%/*}
    name=${schema##*/}
    generated="$dir/${name%.proto}.pb.swift"
    # Quiet on success: protoc warns that the include directory it was built
    # beside is gone, which the schemas, importing nothing, never read.
    if ! protoc_log=$("$bin/protoc" --plugin=protoc-gen-swift="$bin/protoc-gen-swift" --swift_out="$out" \
        -I "$dir" "${options[@]}" "$name" 2>&1); then
        printf '%s\n' "$protoc_log" >&2
        echo "check-generated-protos: protoc failed on $schema" >&2
        status=1
        continue
    fi
    if [ "$write" -eq 1 ]; then
        cp "$out/${name%.proto}.pb.swift" "$generated"
        pass "$generated regenerated"
    elif cmp -s "$out/${name%.proto}.pb.swift" "$generated"; then
        pass "$generated matches $name"
    else
        diff -u "$generated" "$out/${name%.proto}.pb.swift" | head -40 >&2
        echo "check-generated-protos: $generated differs from what $name generates; run Tools/check-generated-protos.sh --write" >&2
        status=1
    fi
done

exit "$status"
