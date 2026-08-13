#!/usr/bin/env bash
# The two app entitlement plists are parallel by design:
# Kernova.entitlements is the shipping set, Kernova.Development.entitlements
# the same set minus the restricted key an unauthorized signature cannot
# carry. Nothing else enforces that parity — Xcode's Signing & Capabilities
# editor writes only to whichever file KERNOVA_APP_ENTITLEMENTS selects, so a
# capability added there would otherwise drift into one variant silently.
# Fails lint when the key sets differ by anything other than the restricted
# key. Values are not compared: every key is a boolean grant, and a key
# present with a non-true value fails at signing, not silently.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

full="Kernova/Resources/Kernova.entitlements"
dev="Kernova/Resources/Kernova.Development.entitlements"
restricted="com.apple.vm.networking"

keys() {
    plutil -convert xml1 -o - "$1" | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' | sort
}

status=0

if ! keys "$full" | grep -Fxq "$restricted"; then
    echo "check-entitlements: $restricted missing from $full" >&2
    status=1
fi

if keys "$dev" | grep -Fxq "$restricted"; then
    echo "check-entitlements: $restricted must not be in $dev" >&2
    status=1
fi

if ! diff_out=$(diff <(keys "$full" | grep -Fxv "$restricted") <(keys "$dev")); then
    echo "check-entitlements: key sets diverge beyond the restricted key ($restricted):" >&2
    echo "$diff_out" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "  ✓ entitlements: variant key parity"
fi
exit "$status"
