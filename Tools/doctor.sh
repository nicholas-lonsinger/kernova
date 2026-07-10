#!/usr/bin/env bash
# Kernova environment doctor.
#
# Verifies that the local toolchain matches what Kernova needs to build, test,
# lint, and push. Run via `make doctor` (or directly: `Tools/doctor.sh`).
#
# It prints one line per check and keeps going after failures so a single run
# reports *everything* that's wrong, then exits non-zero if any REQUIRED check
# failed (optional/tooling checks only warn). That makes it usable both as a
# human sanity check and as a scriptable gate in CI.
#
# This is intentionally a starting point — grow it by appending checks in the
# sections below (a `pass`/`warn`/`fail` per check).
#
# Requirements checked here mirror README.md "Requirements" and the toolchain
# the Makefile actually invokes (e.g. `xcrun swift-format`).

set -uo pipefail

# Run from the repo root so the Signing section's repo-relative paths
# (Config/Local.xcconfig, Tools/bootstrap-team.sh) resolve no matter where the
# script is invoked from — the header advertises direct invocation, and the
# other checks (git config, xcrun, sw_vers) are already cwd-independent.
cd "$(dirname "$0")/.." || exit 1

# ---- output helpers ---------------------------------------------------------

# Count REQUIRED failures so the run can exit non-zero at the end rather than
# bailing on the first one.
fail_count=0

# Colour only when writing to a TTY — keep CI logs and pipes plain.
if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yellow=$'\033[0;33m'
    c_dim=$'\033[0;90m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_yellow=''; c_dim=''; c_bold=''; c_reset=''
fi

pass()    { printf '  %s✓%s %s\n' "$c_green"  "$c_reset" "$1"; }
warn()    { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$1"; }
fail()    { printf '  %s✗%s %s\n' "$c_red"    "$c_reset" "$1"; fail_count=$((fail_count + 1)); }
detail()  { printf '    %s%s%s\n' "$c_dim"    "$1" "$c_reset"; }
section() { printf '\n%s%s%s\n' "$c_bold" "$1" "$c_reset"; }

# major_of "26.5.2" -> "26"; empty input stays empty.
major_of() { printf '%s' "${1:-}" | cut -d. -f1; }

# ge_major MAJOR MIN -> 0 (true) when MAJOR is a number >= MIN. Guards against
# non-numeric input so a failed version probe can't crash the `[` comparison.
ge_major() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge "$2" ] ;;
    esac
}

printf '%sKernova environment doctor%s\n' "$c_bold" "$c_reset"

# ---- platform ---------------------------------------------------------------

section 'Platform'

os_ver=$(sw_vers -productVersion 2>/dev/null || echo '')
if ge_major "$(major_of "$os_ver")" 26; then
    pass "macOS $os_ver (>= 26 required)"
else
    fail "macOS 26 (Tahoe) or later required — found ${os_ver:-unknown}"
fi

# Probe the hardware, not the running process's slice: `uname -m` reports the
# caller's architecture, so an x86_64/Rosetta shell on an Apple-Silicon Mac
# would wrongly report x86_64. `hw.optional.arm64` reflects the CPU itself.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    pass "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64))"
else
    fail "Apple Silicon (arm64) required — this Mac is not Apple Silicon"
    detail "Virtualization.framework's macOS-guest and save/restore APIs are arm64-only."
fi

# ---- toolchain --------------------------------------------------------------

section 'Toolchain'

# `xcodebuild` needs a full Xcode selected, not the Command Line Tools.
dev_dir=$(xcode-select -p 2>/dev/null || echo '')
case "$dev_dir" in
    '')
        fail "Xcode not found — xcode-select has no active developer directory"
        detail "Install Xcode 26+ then: sudo xcode-select -s /Applications/Xcode.app"
        ;;
    *CommandLineTools*)
        fail "Full Xcode required, but Command Line Tools are selected ($dev_dir)"
        detail "Fix: sudo xcode-select -s /Applications/Xcode.app"
        ;;
    *)
        xc_ver=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
        if ge_major "$(major_of "$xc_ver")" 26; then
            pass "Xcode $xc_ver (>= 26 required)"
        else
            fail "Xcode 26 or later required — found ${xc_ver:-unknown}"
        fi
        ;;
esac

# Swift 6 (strict concurrency is assumed throughout the codebase). Probe via
# `xcrun` so this reflects the selected Xcode's toolchain — the one the build
# actually uses — not whatever a bare `swift` resolves to on PATH (same
# rationale as the swift-format probe below).
swift_ver=$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p')
if ge_major "$(major_of "$swift_ver")" 6; then
    pass "Swift $swift_ver (>= 6 required)"
else
    fail "Swift 6 or later required — found ${swift_ver:-unknown}"
fi

# swift-format ships inside the Xcode toolchain; `make format`/`make lint`
# reach it via `xcrun swift-format`, so probe it the same way.
if sf_path=$(xcrun --find swift-format 2>/dev/null); then
    pass "swift-format available (make format / make lint)"
    detail "$sf_path"
else
    fail "swift-format not found in the active Xcode toolchain"
    detail "It ships with Xcode 26+. Confirm your Xcode is selected: xcode-select -p"
fi

# ---- repository -------------------------------------------------------------

section 'Repository'

# core.hooksPath is shared across worktrees, so this is accurate from anywhere
# in the checkout. Missing hooks don't block a build, so warn rather than fail
# (same stance as the Makefile's check-hooks nudge).
hooks_path=$(git config --get core.hooksPath 2>/dev/null || echo '')
if [ "$hooks_path" = ".githooks" ]; then
    pass "git hooks installed (core.hooksPath = .githooks): pre-push lint, post-checkout team bootstrap"
else
    warn "git hooks not installed — run 'make install-hooks' (one-time per clone)"
fi

# ---- signing ------------------------------------------------------------

section 'Signing'

# Debug's three Manual/profile-less sub-targets (agent, agent File Provider,
# host File Provider) need DEVELOPMENT_TEAM resolved before they can sign —
# `make bootstrap` (Tools/bootstrap-team.sh) derives it from your own signing
# certificate into the gitignored Config/Local.xcconfig (#476). CI can't catch
# a broken team here: it builds with CODE_SIGNING_ALLOWED=NO.
local_xcconfig="Config/Local.xcconfig"
resolved_team=""
if [ -f "$local_xcconfig" ]; then
    resolved_team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([^[:space:];]*\).*/\1/p' "$local_xcconfig" | head -1)
fi

if [ -n "$resolved_team" ]; then
    pass "DEVELOPMENT_TEAM = $resolved_team ($local_xcconfig)"
else
    warn "No signing team derived yet — run 'make bootstrap' (one-time per clone/worktree)"
fi

# `security find-identity` lists every codesigning-capable identity in the
# keychain; same detection this repo's bootstrap script uses.
identities=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '^[[:space:]]*[0-9]+\)')
if [ -n "$identities" ]; then
    pass "Codesigning identity available in keychain"
else
    warn "No codesigning identity found — sign into Xcode ▸ Settings ▸ Accounts with your Apple ID"
fi

# Cross-check the resolved team against every team currently in the keychain,
# via bootstrap-team.sh's own --check (dry-run) mode — reusing its derivation
# logic rather than a second copy that could drift. Membership, not equality:
# a resolved team that isn't the top preference but is still a real identity
# (e.g. hand-pinned across multiple Apple IDs) is not a problem.
if [ -n "$resolved_team" ] && [ -n "$identities" ]; then
    if current_teams=$(Tools/bootstrap-team.sh --check 2>/dev/null); then
        if printf '%s\n' "$current_teams" | grep -qxF "$resolved_team"; then
            pass "Resolved team matches a current keychain identity"
        else
            warn "DEVELOPMENT_TEAM ($resolved_team) doesn't match any current keychain identity"
            detail "Available: $(printf '%s' "$current_teams" | tr '\n' ' ')"
            detail "Re-derive with: Tools/bootstrap-team.sh --force"
        fi
    fi
fi

# ---- optional tooling -------------------------------------------------------

section 'Optional tooling'

# Only needed to regenerate kernova.pb.swift after editing the .proto; the
# generated files are checked in, so a normal build/test loop doesn't need it.
if command -v protoc >/dev/null 2>&1 && command -v protoc-gen-swift >/dev/null 2>&1; then
    pass "proto toolchain present (protoc + protoc-gen-swift) — Tools/regen-proto.sh"
else
    warn "proto toolchain absent — only needed to regenerate .pb.swift from kernova.proto"
    detail "Install with: brew install protobuf swift-protobuf"
fi

# ---- summary ----------------------------------------------------------------

if [ "$fail_count" -eq 0 ]; then
    printf '\n%sAll required checks passed.%s\n' "$c_green" "$c_reset"
    exit 0
else
    printf '\n%s%d required check(s) failed — see above.%s\n' "$c_red" "$fail_count" "$c_reset"
    exit 1
fi
