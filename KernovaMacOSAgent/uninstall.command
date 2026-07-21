#!/bin/bash
set -euo pipefail

# -y/--yes: non-interactive mode for scripted uninstalls (test rigs, automated
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

trap 'echo ""; echo "ERROR: An unexpected error occurred (line $LINENO)."; pause' ERR

# The File Provider extension executable's bundle-internal path, used as a
# pgrep/pkill -f pattern. Anchoring on the .appex path matches only the real
# extension process — not unrelated processes whose arguments merely mention
# the name.
FP_EXEC_PATTERN="KernovaMacOSAgentFileProvider\.appex/Contents/MacOS/KernovaMacOSAgentFileProvider"

# Kill the running File Provider extension (if any) and confirm it exited —
# fileproviderd would keep the already-spawned process serving the domain
# after the bundle is deleted otherwise (docs/CLIPBOARD.md, Engineering
# practices). SIGTERM first, SIGKILL after 5s. A no-match is fine; a process
# that survives SIGKILL only warns — it lingers until the guest is rebooted.
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
            echo "WARNING: The File Provider extension process is still running; it"
            echo "         may linger until the guest is rebooted."
            return 0
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
}

# Boot out a LaunchAgent label and wait for launchd to actually drop it —
# bootout returns before teardown completes, and deleting the bundle under a
# still-draining agent defeats the point of stopping it first. A label that
# was never loaded returns immediately.
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

echo "========================================"
echo "  Kernova Guest Agent — Uninstaller"
echo "========================================"
echo ""
echo "This will remove the Kernova guest agent from this Mac."
echo ""
echo "  App:         ~/Applications/Kernova Guest Agent.app"
echo "  LaunchAgent: ~/Library/LaunchAgents/app.kernova.macosagent.plist"
echo ""
if (( ASSUME_YES )); then
    echo "Proceeding without confirmation (--yes)."
    choice="y"
else
    read -r -p "Proceed with uninstall? [y/N] " choice
fi
if [[ "${choice}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "----------------------------------------"

    LABEL="app.kernova.macosagent"
    INSTALL_DIR="${HOME}/Applications"
    APP_NAME="Kernova Guest Agent.app"
    LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
    PLIST_NAME="${LABEL}.plist"

    # Legacy (pre-app-bundle) install location, cleaned up if still present.
    LEGACY_DIR="${HOME}/Library/Application Support/Kernova"
    LEGACY_BINARY="${LEGACY_DIR}/kernova-agent"

    echo "Uninstalling..."

    # Stop the agent and wait for launchd to drop the label.
    bootout_and_wait "${LABEL}"

    # Also kill the running File Provider extension so no process lingers from
    # the deleted bundle.
    stop_file_provider

    # RATIONALE: rm is used instead of trash because this runs inside a guest VM
    # where the trash CLI is not a standard macOS utility, and Finder-based trash
    # (osascript) requires a GUI session that may not be available in headless VMs.
    rm -rf "${INSTALL_DIR:?}/${APP_NAME}"
    # Also remove the pre-rename app bundle name if a stale copy lingers, and
    # any staging/backup leftovers from an interrupted install.
    rm -rf "${INSTALL_DIR}/KernovaGuestAgent.app"
    rm -rf "${INSTALL_DIR}/.${APP_NAME}.staging."* "${INSTALL_DIR}/.${APP_NAME}.previous."*
    rm -f "${LAUNCHAGENTS_DIR}/${PLIST_NAME}"

    # Also boot out and remove the pre-rename LaunchAgent (label app.kernova.agent).
    bootout_and_wait "app.kernova.agent"
    rm -f "${LAUNCHAGENTS_DIR}/app.kernova.agent.plist"

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

pause
