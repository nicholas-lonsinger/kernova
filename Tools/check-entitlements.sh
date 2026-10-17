#!/usr/bin/env bash
# The two app entitlement plists are parallel: Kernova.entitlements is the
# shipping set, Kernova.Development.entitlements the same set minus the
# restricted keys an unauthorized signature cannot carry. Nothing else enforces
# that parity — Xcode's Signing & Capabilities editor writes only to whichever
# file KERNOVA_APP_ENTITLEMENTS selects, so a capability added there would
# otherwise drift into one variant silently. Fails lint when the key sets
# differ by anything other than a restricted key. Values are not compared:
# every key is a boolean grant, and a key present with a non-true value fails
# at signing, not silently.
#
# The test host signs under whatever identity a checkout has, ad-hoc
# included, so its plist — the one its xcconfig names — holds no restricted
# key either. A plist that is missing or unreadable fails the check.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

full="Kernova/Resources/Kernova.entitlements"
dev="Kernova/Resources/Kernova.Development.entitlements"
host_xcconfig="Config/Targets/KernovaTestHost.xcconfig"

# Every key amfid treats as restricted: claiming one under an ad-hoc signature
# is fatal at exec ("adhoc signed but contains restricted entitlements"), so
# each belongs in the shipping set and in neither the development set nor any
# profile-less build.
restricted=(
    "com.apple.vm.networking"
    "com.apple.developer.accessory-access.usb"
    "com.apple.developer.networking.topology-observation"
)

# keys <plist> — its top-level keys, sorted; fails, naming the file, when
# plutil cannot read it.
keys() {
    local xml
    if ! xml=$(plutil -convert xml1 -o - "$1" 2>&1); then
        echo "check-entitlements: cannot read $1: $xml" >&2
        return 1
    fi
    sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' <<<"$xml" | sort
}

# The restricted keys, one per line, sorted — the form `grep -F -x -v -f` and
# `comm` both want.
restricted_lines() {
    printf '%s\n' "${restricted[@]}" | sort
}

test_host=$(sed -n 's/^[[:space:]]*CODE_SIGN_ENTITLEMENTS[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$host_xcconfig" 2>/dev/null | head -1)
if [ -z "$test_host" ]; then
    echo "check-entitlements: $host_xcconfig assigns no CODE_SIGN_ENTITLEMENTS" >&2
    exit 1
fi

full_keys=$(keys "$full") || exit 1
dev_keys=$(keys "$dev") || exit 1
host_keys=$(keys "$test_host") || exit 1

status=0

for key in "${restricted[@]}"; do
    if ! grep -Fxq "$key" <<<"$full_keys"; then
        echo "check-entitlements: $key missing from $full" >&2
        status=1
    fi
    if grep -Fxq "$key" <<<"$dev_keys"; then
        echo "check-entitlements: $key must not be in $dev" >&2
        status=1
    fi
    if grep -Fxq "$key" <<<"$host_keys"; then
        echo "check-entitlements: $key must not be in $test_host" >&2
        status=1
    fi
done

if ! diff_out=$(diff <(grep -Fxv -f <(restricted_lines) <<<"$full_keys") <(printf '%s\n' "$dev_keys")); then
    echo "check-entitlements: key sets diverge beyond the restricted keys:" >&2
    restricted_lines | sed 's/^/  /' >&2
    echo "$diff_out" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    pass "entitlements: variant key parity; no restricted key in the test host's $test_host"
fi
exit "$status"
