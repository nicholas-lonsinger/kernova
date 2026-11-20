#!/usr/bin/env bash
# The Swift generated from each protobuf schema is checked in next to it, so no
# build runs `protoc`: swift-protobuf's build plugin compiles `protoc` from
# source on every host, and that compile fails for Windows arm64 (abseil built
# without NOMINMAX, then a clang backend crash on upb's inline-asm varint
# encoder). This check regenerates every file with the `protoc` and
# `protoc-gen-swift` of the swift-protobuf revision Kernova.xcodeproj's
# Package.resolved pins, and fails on any difference.
#
# Tools/install-protoc.sh builds the tools from a fetch of that exact revision.
#
# Usage: Tools/check-generated-protos.sh [--write]
#   --write   replaces each generated file with the regenerated one
#
# make lint: runs last — a cold cache builds protoc and protoc-gen-swift (minutes)

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# Every tracked schema; its generated file is `<name>.pb.swift` in the same
# directory, which is also the import root.
schemas=()
while IFS= read -r schema; do
    schemas+=("$schema")
done < <(git ls-files '*.proto')
if [ "${#schemas[@]}" -eq 0 ]; then
    echo 'check-generated-protos: git tracks no .proto files — not a git checkout?' >&2
    exit 1
fi
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

protoc=$("$lib_dir/install-protoc.sh") || exit 1
bin=${protoc%/*}

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
