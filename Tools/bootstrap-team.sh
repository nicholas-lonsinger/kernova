#!/usr/bin/env bash
# Derives DEVELOPMENT_TEAM from the developer's own signing certificate and
# writes it to the gitignored Config/Local.xcconfig, included by the tracked
# Config/Base.xcconfig (see that file). This is what makes a fresh clone
# build and sign with *your* team instead of a hardcoded owner team (#476).
#
# Reads the certificate's Subject **OU** field, not the CN parenthetical —
# for an "Apple Development" identity those two differ (the CN parenthetical
# is a per-certificate identifier, e.g. WN57KR9TLZ; the real team ID lives in
# OU, e.g. 8MT4P4GZL2). Using the parenthetical silently produces a team ID
# that doesn't match any of your provisioning, so this script only ever reads
# OU.
#
# Run via `make bootstrap` (also run automatically by `make build`/`make
# test` when Config/Local.xcconfig is missing). Direct invocation:
# Tools/bootstrap-team.sh [--force|--check]
#
# Idempotent: no-ops if Config/Local.xcconfig already has a non-empty
# DEVELOPMENT_TEAM, so a manual override survives re-runs. Pass --force to
# re-derive anyway. Pass --check to print what would be derived, without
# writing anything — Tools/doctor.sh uses this to cross-check a resolved team
# against the keychain, without duplicating the derivation logic here.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# ---- output helpers (matches Tools/doctor.sh / Tools/ls-reset.sh) ----------

if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yellow=$'\033[0;33m'
    c_dim=$'\033[0;90m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_yellow=''; c_dim=''; c_bold=''; c_reset=''
fi

pass()   { printf '  %s✓%s %s\n' "$c_green"  "$c_reset" "$1"; }
warn()   { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$1"; }
fail()   { printf '  %s✗%s %s\n' "$c_red"    "$c_reset" "$1"; }
detail() { printf '    %s%s%s\n' "$c_dim"    "$1" "$c_reset"; }

mode="write"
case "${1:-}" in
    --force) mode="force" ;;
    --check) mode="check" ;;
    "") mode="write" ;;
    *)
        echo "Usage: Tools/bootstrap-team.sh [--force|--check]" >&2
        exit 2
        ;;
esac

[ "$mode" != "check" ] && printf '%sKernova signing team bootstrap%s\n' "$c_bold" "$c_reset"

local_xcconfig="Config/Local.xcconfig"

# ---- idempotency: respect an existing derived or hand-edited value --------
# (--check always re-derives fresh; it never writes, so idempotency doesn't apply.)

if [ "$mode" = "write" ] && [ -f "$local_xcconfig" ]; then
    existing=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([^[:space:];]*\).*/\1/p' "$local_xcconfig" | head -1)
    if [ -n "$existing" ]; then
        pass "Config/Local.xcconfig already sets DEVELOPMENT_TEAM = $existing"
        detail "Re-derive with: Tools/bootstrap-team.sh --force"
        exit 0
    fi
fi

# ---- derive from the developer's own signing certificate -------------------

# Prints the Subject OU (the 10-char Developer Team ID) of the first
# certificate whose common name matches $1, or nothing if none/unparseable.
#
# The `OU *= *\([A-Z0-9]...\)` capture is delimiter-agnostic on purpose: macOS
# LibreSSL (`/usr/bin/openssl`) prints a slash-delimited subject
# (`.../OU=TEAM/O=...`) while Homebrew's OpenSSL 3 (often first on PATH) prints
# it comma-delimited (`..., OU=TEAM, O=...`). A `/OU=`-anchored pattern silently
# yields empty under OpenSSL 3, so match `OU=` regardless of the surrounding
# delimiter and stop the capture at the first non-team character.
ou_for_identity() {
    security find-certificate -c "$1" -p -a 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9][A-Z0-9]*\).*/\1/p' \
        | head -1
}

# Sets derived_common_name / derived_team / derived_all_teams on success.
# Not `local`-scoped: callers need multiple outputs, and a subshell (as a
# `$(...)` capture would create) can't hand back more than one value.
derive_team() {
    # `security find-identity -v -p codesigning` lines look like:
    #   1) E83489ECF11D43E7A93E1DDE70E4672838D52D65 "Apple Development: Nicholas Lonsinger (WN57KR9TLZ)"
    identities=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '^[[:space:]]*[0-9]+\)')
    [ -z "$identities" ] && return 1

    # Prefer "Apple Development" (what Debug's Manual sub-targets sign with);
    # fall back to "Developer ID Application" for a Mac with only a Developer
    # ID cert installed.
    derived_common_name=$(printf '%s\n' "$identities" | grep '"Apple Development:' | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
    if [ -z "$derived_common_name" ]; then
        derived_common_name=$(printf '%s\n' "$identities" | grep '"Developer ID Application:' | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
    fi
    if [ -z "$derived_common_name" ]; then
        # Last resort: whatever the first identity is.
        derived_common_name=$(printf '%s\n' "$identities" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')
    fi
    [ -z "$derived_common_name" ] && return 1

    derived_team=$(ou_for_identity "$derived_common_name")
    printf '%s' "$derived_team" | grep -qE '^[A-Z0-9]{10}$' || return 1

    # Note distinct teams across all identities, in case the chosen one isn't
    # the one the developer expects (e.g. multiple Apple IDs in one keychain).
    derived_all_teams=$(printf '%s\n' "$identities" | sed -n 's/.*"\(.*\)".*/\1/p' | while IFS= read -r cn; do
        ou_for_identity "$cn"
    done | sort -u)
    return 0
}

if ! derive_team; then
    if [ "$mode" = "check" ]; then
        exit 1
    fi
    fail "No codesigning identity found in your keychain"
    detail "Sign into Xcode ▸ Settings ▸ Accounts with your Apple ID, or"
    detail "hand-edit Config/Local.xcconfig with: DEVELOPMENT_TEAM = <your 10-char team ID>"
    exit 1
fi

if [ "$mode" = "check" ]; then
    # Every distinct team currently in the keychain (one per line; always
    # includes derived_team) — lets a caller do membership checks rather than
    # assuming their resolved team must equal the single top-preference pick.
    printf '%s\n' "$derived_all_teams"
    exit 0
fi

distinct_count=$(printf '%s\n' "$derived_all_teams" | grep -c .)

mkdir -p Config
# Built with printf rather than an unquoted here-doc: derived_common_name is
# external data (a certificate common name), so a quoted-delimiter here-doc
# would still not interpolate it and an unquoted one would run any `$(...)` or
# backticks it contained. printf '%s' treats it as literal text. derived_team
# is already validated to ^[A-Z0-9]{10}$ above, so it's safe either way.
{
    printf '// Generated by Tools/bootstrap-team.sh from your "%s" certificate.\n' "$derived_common_name"
    printf '// Delete this file (or re-run with --force) to re-derive; hand-edit to pin a\n'
    printf '// specific team if you have more than one. Gitignored — see Config/Base.xcconfig.\n'
    printf 'DEVELOPMENT_TEAM = %s\n' "$derived_team"
} > "$local_xcconfig"

pass "Derived DEVELOPMENT_TEAM = $derived_team (from \"$derived_common_name\")"
detail "Written to $local_xcconfig"
if [ "$distinct_count" -gt 1 ]; then
    warn "Multiple distinct teams found in your keychain: $(printf '%s' "$derived_all_teams" | tr '\n' ' ')"
    detail "Using $derived_team. Hand-edit $local_xcconfig to pin a different one."
fi
