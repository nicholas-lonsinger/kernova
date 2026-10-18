#!/usr/bin/env bash
# Installs the optional Homebrew tools a make target asks for, skipping the
# ones already on PATH. `make setup` and `make install-lsp` both go through it,
# so there is one answer to "is this tool installed" and one brew invocation
# per run.
#
# Usage: Tools/brew-install.sh <command>...
#   e.g. Tools/brew-install.sh shellcheck gh xcode-build-server
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

for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 && continue
    missing_commands+=("$command_name")
done

if [ "${#missing_commands[@]}" -eq 0 ]; then
    pass "Homebrew tools present: $*"
    exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew absent — still missing: ${missing_commands[*]}"
    detail 'Install Homebrew from https://brew.sh, then re-run `make setup`.'
    exit 0
fi

if ! brew install "${missing_commands[@]}"; then
    warn "brew install did not complete for: ${missing_commands[*]}"
    exit 0
fi

pass "installed: ${missing_commands[*]}"
