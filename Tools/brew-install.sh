#!/usr/bin/env bash
# Installs the optional Homebrew tools a make target asks for, skipping the
# ones already on PATH. `make setup` and `make install-lsp` both go through it,
# so there is one answer to "is this tool installed" and one brew invocation
# per run.
#
# Usage: Tools/brew-install.sh <command>[:<formula>]...
#   e.g. Tools/brew-install.sh shellcheck gh protoc:protobuf
# The formula name defaults to the command name; spell it only where they
# differ (protoc comes from protobuf).
#
# None of these tools is needed to build or test Kernova, so a machine without
# Homebrew gets one line naming what stayed missing and a zero exit — the
# caller carries on, and `make doctor` reports the resulting state.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

[ "$#" -gt 0 ] || exit 0

missing_commands=()
missing_formulas=()
requested=()

for spec in "$@"; do
    command_name="${spec%%:*}"
    formula="${spec#*:}"
    requested+=("$command_name")
    command -v "$command_name" >/dev/null 2>&1 && continue
    missing_commands+=("$command_name")
    missing_formulas+=("$formula")
done

if [ "${#missing_formulas[@]}" -eq 0 ]; then
    pass "Homebrew tools present: ${requested[*]}"
    exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew absent — still missing: ${missing_commands[*]}"
    detail 'Install Homebrew from https://brew.sh, then re-run `make setup`.'
    exit 0
fi

if ! brew install "${missing_formulas[@]}"; then
    warn "brew install did not complete for: ${missing_commands[*]}"
    exit 0
fi

pass "installed: ${missing_commands[*]}"
