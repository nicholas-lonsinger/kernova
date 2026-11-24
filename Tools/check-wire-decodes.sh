#!/usr/bin/env bash
# Outside KernovaWire, a protobuf payload is decoded only through `init(wire:)`,
# whose message type picks the mode: a current-only message is refused when it
# holds a field this build does not define, a FROZEN one ignores it.
# SwiftProtobuf's own binary decode ignores such a field in every message, so a
# call to it elsewhere would read a field another build moved as absent.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

findings=$(git grep -n -E '(serializedBytes|serializedData|contiguousBytes)[[:space:]]*:|BinaryDelimited' \
    -- '*.swift' ':!KernovaKit/Sources/KernovaWire/')
case $? in
    0)
        printf '%s\n' "$findings" >&2
        echo "check-wire-decodes: decode these with init(wire:) (KernovaKit/Sources/KernovaWire/WireMessage.swift)" >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "check-wire-decodes: git grep failed" >&2
        exit 1
        ;;
esac

pass "wire decodes: SwiftProtobuf's binary decode is called only in KernovaWire"
