#!/bin/bash
set -euo pipefail
trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; echo ""; read -p "Press Enter to exit..."' ERR

echo "========================================"
echo "  Kernova Guest Agent — Uninstaller"
echo "========================================"
echo ""
echo "This will remove the Kernova guest agent from this Mac."
echo ""
echo "  Binary:      ~/Library/Application Support/Kernova/kernova-agent"
echo "  LaunchAgent: ~/Library/LaunchAgents/com.kernova.agent.plist"
echo ""
read -p "Proceed with uninstall? [y/N] " choice
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="com.kernova.agent"
    INSTALL_DIR="${HOME}/Library/Application Support/Kernova"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    BINARY_NAME="kernova-agent"
    PLIST_NAME="${LABEL}.plist"

    echo "Uninstalling..."

    # Stop the agent
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    # RATIONALE: rm is used instead of trash because this runs inside a guest VM
    # where the trash CLI is not a standard macOS utility, and Finder-based trash
    # (osascript) requires a GUI session that may not be available in headless VMs.
    rm -f "${INSTALL_DIR}/${BINARY_NAME}"
    rm -f "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"

    # Remove directory if empty
    rmdir "${INSTALL_DIR}" 2>/dev/null || true

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
