#!/usr/bin/env bash
# Regenerate Swift bindings for kernova.proto. Run via `make regen-proto` after
# any edit to KernovaKit/Proto/kernova.proto; the generated files are checked in
# so the SPM package builds with no external tooling step in the normal dev loop.
#
# The generator is built here from the swift-protobuf revision pinned in the
# xcworkspace's Package.resolved rather than taken from PATH. Its output varies
# by version, so a generator picked up from PATH emits bindings that
# .github/workflows/proto-drift.yml — which builds from the pin — rejects, and
# the committed artifact records no version, so the mismatch stays invisible
# until CI regenerates. Building it makes the two generators identical by
# construction, and mirroring Package.resolved into the package keeps the
# generator on the same source tree as the runtime the app links.
#
# The first run pays a release build of swift-protobuf; later runs reuse
# KernovaKit/.build.
#
# protoc is Homebrew's (`brew install protobuf`). Homebrew offers no supported
# way to install a given version, so protoc's version is verified rather than
# acquired: PROTOC_VERSION is the one the committed bindings were generated
# with, and changing it means regenerating and committing in the same change.

set -euo pipefail

PROTOC_VERSION=35.1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="${REPO_ROOT}/KernovaKit/Proto"
OUT_DIR="${REPO_ROOT}/KernovaKit/Sources/KernovaKit/Generated"
PACKAGE_DIR="${REPO_ROOT}/KernovaKit"
WORKSPACE_RESOLVED="${REPO_ROOT}/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PROTOBUF_CHECKOUT="${PACKAGE_DIR}/.build/checkouts/swift-protobuf"

if ! command -v protoc >/dev/null 2>&1; then
    echo "ERROR: protoc not found on PATH. Run 'brew install protobuf'." >&2
    exit 1
fi

# `protoc --version` prints e.g. `libprotoc 35.1`.
found_protoc="$(protoc --version | awk '{print $2}')"
if [ "$found_protoc" != "$PROTOC_VERSION" ]; then
    echo "ERROR: protoc ${found_protoc} is not the ${PROTOC_VERSION} the committed bindings were generated with." >&2
    echo "       A different protoc can change the output, which proto-drift then rejects." >&2
    echo "       If the new version is intended, set PROTOC_VERSION=${found_protoc} in this script," >&2
    echo "       re-run it, and commit the regenerated bindings in the same change." >&2
    exit 1
fi

if [ ! -f "$WORKSPACE_RESOLVED" ]; then
    echo "ERROR: no Package.resolved at ${WORKSPACE_RESOLVED}." >&2
    exit 1
fi

# Resolve against the xcworkspace's pin rather than Package.swift's `from:`
# constraint, which permits a newer minor than the app actually links.
#
# Conditional because `swift package resolve` re-verifies the checkout and
# invalidates its build cache even when nothing changed: measured here, a
# generator rebuild costs ~2s on its own and ~31s when a resolve precedes it.
# A changed pin still takes the slow path, which is when it is warranted.
if ! cmp -s "$WORKSPACE_RESOLVED" "${PACKAGE_DIR}/Package.resolved" \
    || [ ! -d "$PROTOBUF_CHECKOUT" ]; then
    cp "$WORKSPACE_RESOLVED" "${PACKAGE_DIR}/Package.resolved"
    swift package --package-path "$PACKAGE_DIR" resolve
fi

swift build --package-path "$PROTOBUF_CHECKOUT" -c release --product protoc-gen-swift
PROTOC_GEN_SWIFT="${PROTOBUF_CHECKOUT}/.build/release/protoc-gen-swift"

if [ ! -x "$PROTOC_GEN_SWIFT" ]; then
    echo "ERROR: protoc-gen-swift was not built at ${PROTOC_GEN_SWIFT}." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# --plugin names the binary explicitly; without it protoc searches PATH, where
# any Homebrew-installed copy would take precedence over the build above.
protoc \
    --plugin=protoc-gen-swift="${PROTOC_GEN_SWIFT}" \
    --proto_path="${PROTO_DIR}" \
    --swift_out="${OUT_DIR}" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    "${PROTO_DIR}/kernova.proto"

# Named on the way out so a drift failure can be attributed without re-running.
echo "Regenerated Swift bindings in ${OUT_DIR}"
echo "  protoc           ${found_protoc}"
echo "  protoc-gen-swift $("$PROTOC_GEN_SWIFT" --version | awk '{print $2}') (pinned in Package.resolved)"
