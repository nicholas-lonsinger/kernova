#!/usr/bin/env bash
# Regenerate Swift bindings for kernova.proto.
#
# Run this after any edit to KernovaProtocol/Proto/kernova.proto. The generated
# files are checked into the repo so the SPM package builds with no external
# tooling step in the normal dev loop.
#
# Requires: protoc + protoc-gen-swift on PATH (`brew install protobuf swift-protobuf`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="${REPO_ROOT}/KernovaProtocol/Proto"
OUT_DIR="${REPO_ROOT}/KernovaProtocol/Sources/KernovaProtocol/Generated"

if ! command -v protoc >/dev/null 2>&1; then
    echo "ERROR: protoc not found on PATH. Run 'brew install protobuf'." >&2
    exit 1
fi

if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "ERROR: protoc-gen-swift not found on PATH. Run 'brew install swift-protobuf'." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

protoc \
    --proto_path="${PROTO_DIR}" \
    --swift_out="${OUT_DIR}" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    "${PROTO_DIR}/kernova.proto"

echo "Regenerated Swift bindings in ${OUT_DIR}"
