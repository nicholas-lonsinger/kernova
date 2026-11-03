#!/bin/bash
#
# Removes the Kernova guest agent: the install "Just for me" of the user
# running it, or the install "For everyone", which needs an administrator
# password once. The agent's own `uninstall` command does the work; this prints
# what it will do, waits for Return, and runs it, under sudo for "For everyone".
#
# Usage: uninstall.command [--system]
#   --system         remove the install for everyone without asking which
# NONINTERACTIVE=1   ask nothing, and run sudo with -n, so a run without
#                    passwordless sudo stops instead of waiting for a password

set -euo pipefail

DISK="$(cd "$(dirname "$0")" && pwd)"
AGENT="${DISK}/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent"
interactive=1
[ -n "${NONINTERACTIVE:-}" ] && interactive=0

pause() {
    if (( interactive )); then
        echo ""
        read -r -p "Press Return to close this window." _ || true
    fi
}

fail() {
    echo "" >&2
    echo "ERROR: $*" >&2
    pause
    exit 1
}

scope=""
case "${1:-}" in
    --system) scope=system ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--system]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    fail "Run this as your own user, not as root or with sudo. It asks for sudo itself when you remove the install for everyone."
fi

echo "========================================"
echo "  Kernova Guest Agent — Uninstaller"
echo "========================================"
echo ""

if [ -z "${scope}" ]; then
    if (( interactive )); then
        echo "Remove the agent installed:"
        echo "  1) Just for me"
        echo "  2) For everyone (asks for an administrator password)"
        read -r -p "Choose 1 or 2 [1]: " choice || choice=""
        case "${choice}" in
            2) scope=system ;;
            ""|1) scope=user ;;
            *) fail "Choose 1 or 2." ;;
        esac
        echo ""
    else
        scope=user
    fi
fi

uninstall=("${AGENT}" uninstall)
[ "${scope}" = system ] && uninstall=("${AGENT}" uninstall --system)

"${uninstall[@]}" --dry-run || fail "The agent on this disk could not plan the uninstall."
echo ""
if (( interactive )); then
    read -r -p "Press Return to uninstall, or Control-C to cancel." _
    echo ""
fi

if [ "${scope}" = system ]; then
    sudo=(/usr/bin/sudo)
    (( interactive )) || sudo+=(-n)
    printf '==>'
    printf ' %q' "${sudo[@]}" "${uninstall[@]}"
    echo ""
    "${sudo[@]}" "${uninstall[@]}" || fail "The uninstall did not finish."
else
    "${uninstall[@]}" || fail "The uninstall did not finish."
fi
pause
