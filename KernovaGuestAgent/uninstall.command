#!/bin/bash
set -euo pipefail
trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; echo ""; read -p "Press Enter to exit..."' ERR

echo "========================================"
echo "  Kernova Guest Agent — Uninstaller"
echo "========================================"
echo ""
echo "This will remove the Kernova guest agent from this Mac."
echo ""
echo "  App:         ~/Applications/Kernova Guest Agent.app"
echo "  LaunchAgent: ~/Library/LaunchAgents/app.kernova.agent.plist"
echo ""
read -p "Proceed with uninstall? [y/N] " choice
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="app.kernova.agent"
    INSTALL_DIR="${HOME}/Applications"
    APP_NAME="Kernova Guest Agent.app"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    PLIST_NAME="${LABEL}.plist"

    # Legacy (pre-app-bundle) install location, cleaned up if still present.
    LEGACY_DIR="${HOME}/Library/Application Support/Kernova"
    LEGACY_BINARY="${LEGACY_DIR}/kernova-agent"

    echo "Uninstalling..."

    # Stop the agent
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    # RATIONALE: rm is used instead of trash because this runs inside a guest VM
    # where the trash CLI is not a standard macOS utility, and Finder-based trash
    # (osascript) requires a GUI session that may not be available in headless VMs.
    rm -rf "${INSTALL_DIR}/${APP_NAME}"
    # Also remove the pre-rename app bundle name if a stale copy lingers.
    rm -rf "${INSTALL_DIR}/KernovaGuestAgent.app"
    rm -f "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"

    # Remove any leftover legacy bare-binary install.
    rm -f "${LEGACY_BINARY}"
    rmdir "${LEGACY_DIR}" 2>/dev/null || true

    echo ""
    echo "Kernova Guest Agent has been removed."
    echo ""
    echo "========================================"
    echo "  Uninstall complete."
    echo "========================================"
else
    echo ""
    echo "Cancelled — no changes were made."
fi

echo ""
read -p "Press Enter to exit..."
