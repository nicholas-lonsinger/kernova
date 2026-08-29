#!/usr/bin/env bash
# The VM command core is what every automation surface — AppleScript, the
# kernova:// scheme, the CLI, App Intents — reaches VMs through, so it has to
# stay callable from a process with no UI. Nothing in the compiler enforces
# that: an `import AppKit` under Kernova/Commands compiles fine inside the app
# target and only fails once a headless client tries to link the same code.
# Fails lint when one appears, and when the wire router reaches for the AppKit
# adapter or the concrete core instead of the facade it is meant to depend on.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

core_dir="Kernova/Commands"
router="$core_dir/VMCommandEnvelopeRouter.swift"

status=0

if [ ! -d "$core_dir" ]; then
    echo "check-headless-core: $core_dir is missing" >&2
    exit 1
fi

while IFS= read -r file; do
    if grep -Eq '^import (AppKit|Cocoa|SwiftUI)$' "$file"; then
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
