#!/usr/bin/env bash
# Every build fact belongs in Config/, so every XCBuildConfiguration in
# project.pbxproj carries a baseConfigurationReference and an empty
# buildSettings block. Xcode's Signing & Capabilities editor writes toggles
# (ENABLE_HARDENED_RUNTIME, the RUNTIME_EXCEPTION_* family,
# AUTOMATION_APPLE_EVENTS) straight into the inline block, where they silently
# shadow the xcconfig — this check is what turns that into a lint failure
# instead of a divergence nobody reads.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

pbxproj="Kernova.xcodeproj/project.pbxproj"

if [ ! -f "$pbxproj" ]; then
    echo "check-build-settings-layering: $pbxproj is missing" >&2
    exit 1
fi

violations=$(awk '
    # Pass 1: map each configuration ID to the list that owns it, so a
    # violation names the target rather than a bare hex ID.
    FNR == NR {
        if ($0 ~ /^\t\t[0-9A-Fa-f]+ \/\* Build configuration list for /) {
            owner = $0
            sub(/^.*Build configuration list for /, "", owner)
            sub(/ \*\/ = \{$/, "", owner)
            in_list = 1
            next
        }
        if (in_list) {
            if ($0 ~ /^\t\t\};$/) { in_list = 0; next }
            if ($0 ~ /^\t\t\t\t[0-9A-Fa-f]+ \/\* /) {
                id = $1
                name = $3
                list[id] = owner " " name
            }
        }
        next
    }

    # Pass 2: audit each XCBuildConfiguration block.
    /^\t\t[0-9A-Fa-f]+ \/\* / && !in_block { pending = $1 }
    /^\t\t\tisa = XCBuildConfiguration;$/ {
        in_block = 1
        id = pending
        has_base = 0
        settings = 0
        in_settings = 0
        next
    }
    in_block {
        if ($0 ~ /^\t\t\};$/) {
            label = (id in list) ? list[id] : id
            if (!has_base) print "  " label ": no baseConfigurationReference"
            if (settings) print "  " label ": " settings " inline buildSettings (move them into Config/)"
            in_block = 0
            next
        }
        if ($0 ~ /^\t\t\tbaseConfigurationReference = /) { has_base = 1; next }
        if ($0 ~ /^\t\t\tbuildSettings = \{$/) { in_settings = 1; next }
        if (in_settings) {
            if ($0 ~ /^\t\t\t\};$/) { in_settings = 0; next }
            if ($0 ~ /^\t\t\t\t[A-Z_"]/) settings++
        }
    }
' "$pbxproj" "$pbxproj")

if [ -n "$violations" ]; then
    echo "check-build-settings-layering: $pbxproj holds build settings Config/ should own:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "  ✓ build settings: every configuration is xcconfig-backed with an empty inline block"
