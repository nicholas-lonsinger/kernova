#!/usr/bin/env bash
# The app's Release configuration, which Archive builds, signs with the full
# entitlement set, Kernova/Resources/Kernova.entitlements. No Debug build reads
# that assignment, so a change to it shows first in a shipped archive. Every
# CODE_SIGN_ENTITLEMENTS the app's xcconfig assigns is either Debug's or that
# Release one.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

app=Config/Targets/Kernova.xcconfig
full=Kernova/Resources/Kernova.entitlements

[ -f "$app" ] || { echo "check-release-entitlements: $app is missing" >&2; exit 1; }

# A declaration is NAME, optional [condition] groups, then `=`.
violations=$(awk -v full="$full" '
    {
        line = $0
        sub(/\/\/.*$/, "", line)
        if (!match(line, /^[[:space:]]*CODE_SIGN_ENTITLEMENTS([[:space:]]*\[[^]]*\])*[[:space:]]*=/)) next
        condition = substr(line, 1, RLENGTH)
        value = substr(line, RLENGTH + 1)
        sub(/^[[:space:]]*CODE_SIGN_ENTITLEMENTS/, "", condition)
        sub(/=$/, "", condition)
        gsub(/[[:space:]]/, "", condition)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (condition == "[config=Debug]") next
        if (condition == "[config=Release]" && value == full) { release = 1; next }
        printf "  %s:%d: CODE_SIGN_ENTITLEMENTS%s = %s\n", FILENAME, FNR, condition, value
    }
    END { if (!release) printf "  %s: no CODE_SIGN_ENTITLEMENTS[config=Release] = %s\n", FILENAME, full }
' "$app")

if [ -n "$violations" ]; then
    echo "check-release-entitlements: the app's Release configuration must sign with $full:" >&2
    printf '%s\n' "$violations" >&2
    exit 1
fi

pass "release entitlements: the app's Release configuration signs with $full"
