#!/usr/bin/env bash
# Regenerates the Swift checked in beside each protobuf schema, with the
# `protoc` and `protoc-gen-swift` of the swift-protobuf revision
# Kernova.xcodeproj's Package.resolved pins (Tools/install-protoc.sh). No build
# runs `protoc`: swift-protobuf's build plugin compiles `protoc` from source on
# every host, and that compile fails for Windows arm64 (abseil built without
# NOMINMAX, then a clang backend crash on upb's inline-asm varint encoder).
#
# Usage: Tools/regen-protos.sh

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
    echo 'regen-protos: git tracks no .proto files — not a git checkout?' >&2
    exit 1
fi
options=(--swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores)

protoc=$("$lib_dir/install-protoc.sh") || exit 1
bin=${protoc%/*}

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

status=0
for schema in "${schemas[@]}"; do
    dir=${schema%/*}
    name=${schema##*/}
    # Quiet on success: protoc warns that the include directory it was built
    # beside is gone, which the schemas, importing nothing, never read.
    if ! protoc_log=$("$bin/protoc" --plugin=protoc-gen-swift="$bin/protoc-gen-swift" --swift_out="$out" \
        -I "$dir" "${options[@]}" "$name" 2>&1); then
        printf '%s\n' "$protoc_log" >&2
        echo "regen-protos: protoc failed on $schema" >&2
        status=1
        continue
    fi
    cp "$out/${name%.proto}.pb.swift" "$dir/${name%.proto}.pb.swift"
    pass "$dir/${name%.proto}.pb.swift regenerated"
done

exit "$status"
