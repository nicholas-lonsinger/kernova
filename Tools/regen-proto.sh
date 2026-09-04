#!/usr/bin/env bash
# Regenerate Swift bindings for kernova.proto.
#
# Run this after any edit to KernovaKit/Proto/kernova.proto. The generated
# files are checked into the repo so the SPM package builds with no external
# tooling step in the normal dev loop.
#
# The generator, protoc-gen-swift, is built here from the swift-protobuf
# revision the xcworkspace's Package.resolved pins — the same source tree the
# runtime links against. A generator at any other version emits different
# files, which is what `.github/workflows/proto-drift.yml` fails on; both that
# job and a developer run this one script, so they cannot disagree.
#
# Requires: protoc on PATH (`make setup`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="${REPO_ROOT}/KernovaKit/Proto"
OUT_DIR="${REPO_ROOT}/KernovaKit/Sources/KernovaKit/Generated"
RESOLVED="${REPO_ROOT}/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CHECKOUT="${REPO_ROOT}/KernovaKit/.build/checkouts/swift-protobuf"

if ! command -v protoc >/dev/null 2>&1; then
    echo "ERROR: protoc not found on PATH. Run 'make setup'." >&2
    exit 1
fi

# `swift package resolve` recomputes against Package.swift's `from:` constraint
# unless the package carries the pinned revision, so mirror the xcworkspace's
# file in first. Both it and KernovaKit/.build are gitignored.
#
# `xcrun` so the toolchain matches the selected Xcode, as everywhere else the
# Makefile drives Swift from the terminal. Both steps no-op once built.
cp "$RESOLVED" "${REPO_ROOT}/KernovaKit/Package.resolved"
xcrun swift package --package-path "${REPO_ROOT}/KernovaKit" resolve
xcrun swift build --package-path "$CHECKOUT" -c release --product protoc-gen-swift

PATH="${CHECKOUT}/.build/release:${PATH}"
export PATH

mkdir -p "${OUT_DIR}"

protoc \
    --proto_path="${PROTO_DIR}" \
    --swift_out="${OUT_DIR}" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    "${PROTO_DIR}/kernova.proto"

echo "Regenerated Swift bindings in ${OUT_DIR}"
