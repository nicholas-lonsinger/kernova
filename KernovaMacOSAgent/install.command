#!/bin/bash
set -euo pipefail
trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; echo "Run uninstall.command to clean up, then try again."; echo ""; read -p "Press Enter to exit..."' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/Applications"
APP_NAME="Kernova Guest Agent.app"
APP_SRC="${SCRIPT_DIR}/${APP_NAME}"
APP_DEST="${INSTALL_DIR}/${APP_NAME}"
EXEC_REL="Contents/MacOS/KernovaMacOSAgent"

# Legacy (pre-app-bundle) install location, cleaned up on upgrade.
LEGACY_DIR="${HOME}/Library/Application Support/Kernova"
LEGACY_BINARY="${LEGACY_DIR}/kernova-agent"

# Parse version: "kernova-agent 0.23.0 (42)" → version="0.23.0 (42)", build="42"
NEW_OUTPUT=$("${APP_SRC}/${EXEC_REL}" --version 2>/dev/null) || NEW_OUTPUT=""
NEW_VERSION=$(echo "${NEW_OUTPUT}" | sed 's/^kernova-agent //')
NEW_BUILD=$(echo "${NEW_OUTPUT}" | sed -n 's/.*(\([0-9]*\)).*/\1/p')

if [[ -z "${NEW_VERSION}" ]]; then
    echo "ERROR: Could not determine version of the new agent app."
    echo "The app may not be executable on this system."
    echo ""
    read -p "Press Enter to exit..."
    exit 1
fi

INSTALLED_VERSION=""
INSTALLED_BUILD=""
if [[ -x "${APP_DEST}/${EXEC_REL}" ]]; then
    INSTALLED_OUTPUT=$("${APP_DEST}/${EXEC_REL}" --version 2>/dev/null) || INSTALLED_OUTPUT=""
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
echo "  App:         ~/Applications/Kernova Guest Agent.app"
echo "  LaunchAgent: ~/Library/LaunchAgents/app.kernova.macosagent.plist"
echo ""
echo "To uninstall later, run uninstall.command from this disk."
echo ""
read -p "Proceed? [y/N] " choice
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="app.kernova.macosagent"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    PLIST_NAME="${LABEL}.plist"

    echo "Installing..."

    # Stop any running agent under the current label before replacing it (a
    # pre-rename install ran under app.kernova.agent and is booted out below).
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    # fileproviderd does not replace a running File Provider extension when its
    # app bundle is replaced — the already-spawned process (the old binary) keeps
    # serving the domain (docs/CLIPBOARD.md, Engineering practices). Kill it so
    # the system respawns the new one on demand; a no-match (fresh install, or
    # the extension never launched) is fine.
    pkill -f KernovaMacOSAgentFileProvider 2>/dev/null || true

    # Copy the app bundle with ditto so its code signature and layout survive — a
    # flattened or re-permissioned copy would invalidate the bundle signature and
    # launchd would refuse to exec it.
    mkdir -p "${INSTALL_DIR}"
    rm -rf "${APP_DEST}"
    ditto "${APP_SRC}" "${APP_DEST}"
    # Strip quarantine defensively so launchd/syspolicyd never blocks first exec.
    xattr -dr com.apple.quarantine "${APP_DEST}" 2>/dev/null || true

    # Remove the legacy bare-binary install if present (it ran under the pre-rename
    # app.kernova.agent label, booted out below).
    rm -f "${LEGACY_BINARY}"
    rmdir "${LEGACY_DIR}" 2>/dev/null || true

    # Remove the pre-rename app bundle ("KernovaGuestAgent.app", no spaces) so the
    # rename to "Kernova Guest Agent.app" doesn't leave a stale second copy and a
    # duplicate Login Items entry behind.
    rm -rf "${INSTALL_DIR}/KernovaGuestAgent.app"

    # Remove the pre-rename LaunchAgent (label app.kernova.agent). Its stale plist
    # points at the old KernovaGuestAgent executable, so launchd would spawn-fail it
    # every ThrottleInterval once the bundle's executable is renamed to KernovaMacOSAgent.
    launchctl bootout "gui/$(id -u)/app.kernova.agent" 2>/dev/null || true
    rm -f "${LAUNCHAGENTS_DIR}/app.kernova.agent.plist"

    # Install the LaunchAgent plist with the resolved install path.
    mkdir -p "${LAUNCHAGENTS_DIR}"
    sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "${SCRIPT_DIR}/${PLIST_NAME}" > "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"
    if grep -q '__INSTALL_DIR__' "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"; then
        echo "ERROR: Plist template substitution failed — placeholder still present."
        exit 1
    fi

    # Register with launchd
    launchctl bootstrap "gui/$(id -u)" "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"

    INSTALLED_VER=$("${APP_DEST}/${EXEC_REL}" --version 2>/dev/null) || INSTALLED_VER="(could not determine)"
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
