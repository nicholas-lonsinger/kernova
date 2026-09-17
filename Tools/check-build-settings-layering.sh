#!/usr/bin/env bash
# Every build fact belongs in Config/, so every XCBuildConfiguration in
# project.pbxproj carries a baseConfigurationReference and an empty
# buildSettings block. Xcode's Signing & Capabilities editor writes toggles
# (ENABLE_HARDENED_RUNTIME, the RUNTIME_EXCEPTION_* family,
# AUTOMATION_APPLE_EVENTS) straight into the inline block, where they silently
# shadow the xcconfig — this check is what turns that into a lint failure
# instead of a divergence nobody reads.
#
# The app and both test bundles additionally assign no signing of their own: a
# target xcconfig outranks Config/Local.xcconfig, so an identity, team, profile
# or entitlement path written there reverts a developer to ad-hoc signing while
# `make doctor` goes on reporting Local.xcconfig's values.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

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

# The three targets Config/Local.xcconfig has to reach. KernovaCLI.xcconfig and
# KernovaRelaunchHelper.xcconfig pin Release to `-` on purpose — export
# re-signs them — so they are out of scope here.
signing_files=(
    Config/Targets/Kernova.xcconfig
    Config/Targets/KernovaTests.xcconfig
    Config/Targets/KernovaMacOSAgentTests.xcconfig
)

for f in "${signing_files[@]}"; do
    if [ ! -f "$f" ]; then
        echo "check-build-settings-layering: $f is missing" >&2
        exit 1
    fi
done

# A declaration is NAME, optional [condition] groups, then `=`; the condition
# is part of the spelling, not an escape, so a conditioned assignment fails the
# same way an unconditioned one does.
signing_violations=$(awk '
    {
        line = $0
        sub(/\/\/.*$/, "", line)
        if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*([[:space:]]*\[[^]]*\])*[[:space:]]*=/)) next

        name = substr(line, 1, RLENGTH)
        sub(/([[:space:]]*\[[^]]*\])*[[:space:]]*=$/, "", name)
        value = substr(line, RLENGTH + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

        if (name == "CODE_SIGN_IDENTITY" || name == "DEVELOPMENT_TEAM")
            printf "  %s:%d: %s — Config/Local.xcconfig has to reach this target\n", FILENAME, FNR, name
        else if (name == "PROVISIONING_PROFILE_SPECIFIER" && value != "")
            printf "  %s:%d: %s = %s — leave it empty\n", FILENAME, FNR, name, value
        else if (name == "CODE_SIGN_ENTITLEMENTS" && value != "$(KERNOVA_APP_ENTITLEMENTS)")
            printf "  %s:%d: %s = %s — read $(KERNOVA_APP_ENTITLEMENTS) instead\n", FILENAME, FNR, name, value
    }
' "${signing_files[@]}")

failed=0

if [ -n "$violations" ]; then
    echo "check-build-settings-layering: $pbxproj holds build settings Config/ should own:" >&2
    echo "$violations" >&2
    failed=1
fi

if [ -n "$signing_violations" ]; then
    echo "check-build-settings-layering: a target xcconfig assigns signing Config/Local.xcconfig has to own:" >&2
    echo "$signing_violations" >&2
    failed=1
fi

[ "$failed" -eq 0 ] || exit 1

pass "build settings: every configuration is xcconfig-backed with an empty inline block"
pass "signing: the app and test xcconfigs name no identity, team, profile, or entitlement path"
