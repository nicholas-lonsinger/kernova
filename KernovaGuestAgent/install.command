#!/bin/bash
set -euo pipefail
trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; echo "Run uninstall.command to clean up, then try again."; echo ""; read -p "Press Enter to exit..."' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/Library/Application Support/Kernova"
BINARY_NAME="kernova-agent"

# Parse version: "kernova-agent 0.9.0 (4)" → version="0.9.0 (4)", build="4"
NEW_OUTPUT=$("${SCRIPT_DIR}/${BINARY_NAME}" --version 2>/dev/null) || NEW_OUTPUT=""
NEW_VERSION=$(echo "${NEW_OUTPUT}" | sed 's/^kernova-agent //')
NEW_BUILD=$(echo "${NEW_OUTPUT}" | sed -n 's/.*(\([0-9]*\)).*/\1/p')

if [[ -z "${NEW_VERSION}" ]]; then
    echo "ERROR: Could not determine version of the new agent binary."
    echo "The binary may not be executable on this system."
    echo ""
    read -p "Press Enter to exit..."
    exit 1
fi

INSTALLED_VERSION=""
INSTALLED_BUILD=""
if [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
    INSTALLED_OUTPUT=$("${INSTALL_DIR}/${BINARY_NAME}" --version 2>/dev/null) || INSTALLED_OUTPUT=""
    INSTALLED_VERSION=$(echo "${INSTALLED_OUTPUT}" | sed 's/^kernova-agent //')
    INSTALLED_BUILD=$(echo "${INSTALLED_OUTPUT}" | sed -n 's/.*(\([0-9]*\)).*/\1/p')
fi

echo "========================================"
echo "  Kernova Guest Agent — Installer"
echo "========================================"
echo ""
if [[ -n "${INSTALLED_VERSION}" ]]; then
    if [[ "${INSTALLED_BUILD}" == "${NEW_BUILD}" ]]; then
        echo "  Version ${NEW_VERSION} is already installed. This will reinstall it."
    else
        echo "  Upgrading from ${INSTALLED_VERSION} to ${NEW_VERSION}."
    fi
else
    echo "  Installing version ${NEW_VERSION}."
fi
echo ""
echo "  Binary:      ~/Library/Application Support/Kernova/kernova-agent"
echo "  LaunchAgent: ~/Library/LaunchAgents/com.kernova.agent.plist"
echo ""
echo "To uninstall later, run uninstall.command from this disk."
echo ""
read -p "Proceed? [y/N] " choice
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="com.kernova.agent"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    PLIST_NAME="${LABEL}.plist"

    echo "Installing..."

    # Stop existing agent if running
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    mkdir -p "${INSTALL_DIR}"
    cp "${SCRIPT_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"

    # Install plist with resolved install path
    mkdir -p "${LAUNCHAGENTS_DIR}"
    sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "${SCRIPT_DIR}/${PLIST_NAME}" > "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"
    if grep -q '__INSTALL_DIR__' "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"; then
        echo "ERROR: Plist template substitution failed — placeholder still present."
        exit 1
    fi

    # Register with launchd
    launchctl bootstrap "gui/$(id -u)" "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"

    INSTALLED_VER=$("${INSTALL_DIR}/${BINARY_NAME}" --version 2>/dev/null) || INSTALLED_VER="(could not determine)"
    echo ""
    echo "Installed: ${INSTALLED_VER}"
    echo "LaunchAgent registered as ${LABEL}"
    echo ""
    echo "========================================"
    echo "  Installation complete."
    echo "========================================"
else
    echo ""
    echo "Cancelled — no changes were made."
fi

echo ""
read -p "Press Enter to exit..."
