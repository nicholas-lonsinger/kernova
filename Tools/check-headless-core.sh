#!/usr/bin/env bash
# Checks exactly two things about the VM command core, both of which the
# compiler is happy to let slide inside a single app target:
#
#   1. No file under Kernova/Commands imports AppKit, Cocoa or SwiftUI. That
#      keeps the core's own sources UI-free; it does not make the core headless,
#      because its collaborators still reach AppKit transitively.
#   2. The wire router names neither the AppKit adapter nor the concrete core,
#      only the facade it is meant to depend on.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

core_dir="Kernova/Commands"
router="$core_dir/VMCommandEnvelopeRouter.swift"

status=0

if [ ! -d "$core_dir" ]; then
    echo "check-headless-core: $core_dir is missing" >&2
    exit 1
fi

# Attributes (`@preconcurrency import AppKit`) and submodule imports
# (`import AppKit.NSImage`) are the spellings a plain anchored match misses.
import_pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(AppKit|Cocoa|SwiftUI)([.][A-Za-z_][A-Za-z0-9_]*)*[[:space:]]*$'

while IFS= read -r file; do
    if grep -Eq "$import_pattern" "$file"; then
        echo "check-headless-core: $file imports a UI framework" >&2
        status=1
    fi
done < <(find "$core_dir" -name '*.swift')

if [ ! -f "$router" ]; then
    echo "check-headless-core: $router is missing" >&2
    exit 1
fi

if grep -q 'VMLibraryViewModel' "$router"; then
    echo "check-headless-core: $router reaches the AppKit adapter" >&2
    status=1
fi

if grep -q 'VMCommandCore' "$router"; then
    echo "check-headless-core: $router names the concrete core, not the facade" >&2
    status=1
fi

exit "$status"
