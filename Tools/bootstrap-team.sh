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

    # -a returns every cert matching the common name concatenated as PEM;
    # piping through `openssl x509` reads only the first, which is the match
    # we want.
    subject=$(security find-certificate -c "$derived_common_name" -p -a 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
    derived_team=$(printf '%s' "$subject" | sed -n 's#.*/OU=\([^/]*\).*#\1#p')
    printf '%s' "$derived_team" | grep -qE '^[A-Z0-9]{10}$' || return 1

    # Note distinct teams across all identities, in case the chosen one isn't
    # the one the developer expects (e.g. multiple Apple IDs in one keychain).
    derived_all_teams=$(printf '%s\n' "$identities" | sed -n 's/.*"\(.*\)".*/\1/p' | while IFS= read -r cn; do
        s=$(security find-certificate -c "$cn" -p -a 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
        printf '%s\n' "$s" | sed -n 's#.*/OU=\([^/]*\).*#\1#p'
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
cat > "$local_xcconfig" <<EOF
// Generated by Tools/bootstrap-team.sh from your "$derived_common_name" certificate.
// Delete this file (or re-run with --force) to re-derive; hand-edit to pin a
// specific team if you have more than one. Gitignored — see Config/Base.xcconfig.
DEVELOPMENT_TEAM = $derived_team
EOF

pass "Derived DEVELOPMENT_TEAM = $derived_team (from \"$derived_common_name\")"
detail "Written to $local_xcconfig"
if [ "$distinct_count" -gt 1 ]; then
    warn "Multiple distinct teams found in your keychain: $(printf '%s' "$derived_all_teams" | tr '\n' ' ')"
    detail "Using $derived_team. Hand-edit $local_xcconfig to pin a different one."
fi
