#!/usr/bin/env bash
# The two app entitlement plists are parallel by design:
# Kernova.entitlements is the shipping set, Kernova.Development.entitlements
# the same set minus the restricted keys an unauthorized signature cannot
# carry. Nothing else enforces that parity — Xcode's Signing & Capabilities
# editor writes only to whichever file KERNOVA_APP_ENTITLEMENTS selects, so a
# capability added there would otherwise drift into one variant silently.
# Fails lint when the key sets differ by anything other than a restricted key.
# Values are not compared: every key is a boolean grant, and a key present with
# a non-true value fails at signing, not silently.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

full="Kernova/Resources/Kernova.entitlements"
dev="Kernova/Resources/Kernova.Development.entitlements"

# Every key amfid treats as restricted: claiming one under an ad-hoc signature
# is fatal at exec ("adhoc signed but contains restricted entitlements"), so
# each belongs in the shipping set and in neither the development set nor any
# profile-less build.
restricted=(
    "com.apple.vm.networking"
    "com.apple.developer.accessory-access.usb"
)

keys() {
    plutil -convert xml1 -o - "$1" | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' | sort
}

# The restricted keys, one per line, sorted — the form `grep -F -x -v -f` and
# `comm` both want.
restricted_lines() {
    printf '%s\n' "${restricted[@]}" | sort
}

status=0

for key in "${restricted[@]}"; do
    if ! keys "$full" | grep -Fxq "$key"; then
        echo "check-entitlements: $key missing from $full" >&2
        status=1
    fi
    if keys "$dev" | grep -Fxq "$key"; then
        echo "check-entitlements: $key must not be in $dev" >&2
        status=1
    fi
done

if ! diff_out=$(diff <(keys "$full" | grep -Fxv -f <(restricted_lines)) <(keys "$dev")); then
    echo "check-entitlements: key sets diverge beyond the restricted keys:" >&2
    restricted_lines | sed 's/^/  /' >&2
    echo "$diff_out" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "  ✓ entitlements: variant key parity"
fi
exit "$status"
