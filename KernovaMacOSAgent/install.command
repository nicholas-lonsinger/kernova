#!/bin/bash
set -euo pipefail

# -y/--yes: non-interactive mode for scripted installs (test rigs, automated
# VM provisioning) — skips the confirmation and exit prompts, nothing else.
ASSUME_YES=0
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) ASSUME_YES=1 ;;
        *)
            echo "Usage: $(basename "$0") [-y|--yes]"
            exit 2
            ;;
    esac
done

pause() {
    if (( ASSUME_YES == 0 )); then
        echo ""
        read -r -p "Press Enter to exit..."
    fi
}

trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; echo "Run uninstall.command to clean up, then try again."; if [ -n "${STAGING:-}" ]; then rm -rf "${STAGING}"; fi; pause' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/Applications"
APP_NAME="Kernova Guest Agent.app"
APP_SRC="${SCRIPT_DIR}/${APP_NAME}"
APP_DEST="${INSTALL_DIR}/${APP_NAME}"
EXEC_REL="Contents/MacOS/KernovaMacOSAgent"

# The File Provider extension executable's bundle-internal path, used as a
# pgrep/pkill -f pattern. Anchoring on the .appex path matches only the real
# extension process — not unrelated processes whose arguments merely mention
# the name.
FP_EXEC_PATTERN="KernovaMacOSAgentFileProvider\.appex/Contents/MacOS/KernovaMacOSAgentFileProvider"

# Legacy (pre-app-bundle) install location, cleaned up on upgrade.
LEGACY_DIR="${HOME}/Library/Application Support/Kernova"
LEGACY_BINARY="${LEGACY_DIR}/kernova-agent"

# Kill the running File Provider extension (if any) and confirm it exited —
# fileproviderd does not replace a running extension when its app bundle is
# replaced; the already-spawned process (the old binary) keeps serving the
# domain (docs/CLIPBOARD.md, Engineering practices). SIGTERM first, SIGKILL
# after 5s. A no-match (fresh install, or the extension never launched) is
# fine; a process that survives SIGKILL only warns — it keeps serving the old
# build until the guest is rebooted, but cannot corrupt the install itself.
stop_file_provider() {
    local waited=0 escalated=0
    if ! pgrep -f "${FP_EXEC_PATTERN}" >/dev/null 2>&1; then
        return 0
    fi
    pkill -f "${FP_EXEC_PATTERN}" 2>/dev/null || true
    while pgrep -f "${FP_EXEC_PATTERN}" >/dev/null 2>&1; do
        if (( waited >= 25 && escalated == 0 )); then
            pkill -9 -f "${FP_EXEC_PATTERN}" 2>/dev/null || true
            escalated=1
        fi
        if (( waited >= 35 )); then
            echo "WARNING: The old File Provider extension is still running; the new"
            echo "         one may not take over until the guest is rebooted."
            return 0
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
}

# Boot out a LaunchAgent label and wait for launchd to actually drop it —
# bootout returns before teardown completes, and bootstrapping a label that
# is still draining fails. A label that was never loaded returns immediately.
bootout_and_wait() {
    local label="$1" waited=0
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    while launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; do
        if (( waited >= 25 )); then
            echo "WARNING: ${label} did not stop within 5 seconds; continuing."
            break
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
}

# Parse version: "kernova-agent 0.23.0 (42)" → version="0.23.0 (42)", build="42"
NEW_OUTPUT=$("${APP_SRC}/${EXEC_REL}" --version 2>/dev/null) || NEW_OUTPUT=""
NEW_VERSION="${NEW_OUTPUT#kernova-agent }"
NEW_BUILD=$(echo "${NEW_OUTPUT}" | sed -n 's/.*(\([0-9]*\)).*/\1/p')

if [[ -z "${NEW_VERSION}" ]]; then
    echo "ERROR: Could not determine version of the new agent app."
    echo "The app may not be executable on this system."
    pause
    exit 1
fi

INSTALLED_VERSION=""
INSTALLED_BUILD=""
if [[ -x "${APP_DEST}/${EXEC_REL}" ]]; then
    INSTALLED_OUTPUT=$("${APP_DEST}/${EXEC_REL}" --version 2>/dev/null) || INSTALLED_OUTPUT=""
    INSTALLED_VERSION="${INSTALLED_OUTPUT#kernova-agent }"
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
if (( ASSUME_YES )); then
    echo "Proceeding without confirmation (--yes)."
    choice="y"
else
    read -r -p "Proceed? [y/N] " choice
fi
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="app.kernova.macosagent"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    PLIST_NAME="${LABEL}.plist"

    echo "Installing..."

    # Stage and validate the new bundle first, so nothing existing is stopped
    # or replaced until the copy is known good.
    mkdir -p "${INSTALL_DIR}"
    # Clear leftovers from a previously interrupted run.
    rm -rf "${INSTALL_DIR}/.${APP_NAME}.staging."* "${INSTALL_DIR}/.${APP_NAME}.previous."*
    STAGING="${INSTALL_DIR}/.${APP_NAME}.staging.$$"
    # Copy with ditto so the code signature and bundle layout survive — a
    # flattened or re-permissioned copy would invalidate the bundle signature
    # and launchd would refuse to exec it. Staging next to the destination
    # keeps the final move a same-volume rename.
    ditto "${APP_SRC}" "${STAGING}"
    # Strip quarantine defensively so launchd/syspolicyd never blocks first exec.
    xattr -dr com.apple.quarantine "${STAGING}" 2>/dev/null || true

    STAGED_OUTPUT=$("${STAGING}/${EXEC_REL}" --version 2>/dev/null) || STAGED_OUTPUT=""
    if [[ "${STAGED_OUTPUT}" != "${NEW_OUTPUT}" ]]; then
        echo "ERROR: The staged copy did not pass its version check"
        echo "(expected \"${NEW_OUTPUT}\", got \"${STAGED_OUTPUT:-no output}\")."
        echo "The currently installed agent was not touched."
        rm -rf "${STAGING}"
        pause
        exit 1
    fi
    # If the source bundle carries a verifiable signature, the copy must too —
    # an intact-but-unsigned dev build is not penalized.
    if codesign --verify --deep --strict "${APP_SRC}" >/dev/null 2>&1; then
        if ! codesign --verify --deep --strict "${STAGING}" >/dev/null 2>&1; then
            echo "ERROR: The staged copy failed code-signature verification."
            echo "The currently installed agent was not touched."
            rm -rf "${STAGING}"
            pause
            exit 1
        fi
    fi

    # Stop any running agent under the current label before replacing it (a
    # pre-rename install ran under app.kernova.agent and is booted out below),
    # waiting out the drain so the bootstrap below cannot race it.
    bootout_and_wait "${LABEL}"

    stop_file_provider

    # Swap the validated bundle into place. Renames, not copies: there is no
    # window with a half-written app, and the old bundle survives (as the
    # backup) until the new one is in place.
    BACKUP=""
    if [[ -e "${APP_DEST}" ]]; then
        BACKUP="${INSTALL_DIR}/.${APP_NAME}.previous.$$"
        mv "${APP_DEST}" "${BACKUP}"
    fi
    if ! mv "${STAGING}" "${APP_DEST}"; then
        echo "ERROR: Could not move the new app bundle into place."
        if [[ -n "${BACKUP}" ]]; then
            mv "${BACKUP}" "${APP_DEST}" 2>/dev/null || true
            echo "The previous version was restored."
        fi
        pause
        exit 1
    fi
    if [[ -n "${BACKUP}" ]]; then
        rm -rf "${BACKUP}"
    fi

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
    bootout_and_wait "app.kernova.agent"
    rm -f "${LAUNCHAGENTS_DIR}/app.kernova.agent.plist"

    # Install the LaunchAgent plist with the resolved install path.
    mkdir -p "${LAUNCHAGENTS_DIR}"
    sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "${SCRIPT_DIR}/${PLIST_NAME}" > "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"
    if grep -q '__INSTALL_DIR__' "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"; then
        echo "ERROR: Plist template substitution failed — placeholder still present."
        pause
        exit 1
    fi

    # Register with launchd. Guarded so a failure reports accurately: at this
    # point the bundle and plist are in place, so launchd starts the agent at
    # next login even if this immediate bootstrap fails.
    if ! launchctl bootstrap "gui/$(id -u)" "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"; then
        echo ""
        echo "ERROR: launchctl could not start the agent now."
        echo "The agent is installed and will start at next login; or re-run"
        echo "this installer to try again."
        pause
        exit 1
    fi

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

pause
