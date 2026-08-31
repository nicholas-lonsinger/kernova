#!/bin/bash
#
# package-guest-agent-dmg.sh — stage Kernova Guest Agent.app with its
# install/uninstall commands into a guest-mountable .cdr disk image inside
# Kernova.app, and write the version sidecar the host reads at runtime.
#
# Environment (exported by Xcode): SRCROOT, DERIVED_FILE_DIR,
# BUILT_PRODUCTS_DIR, CONTENTS_FOLDER_PATH.

set -euo pipefail

STAGING_DIR=$(mktemp -d "${DERIVED_FILE_DIR}/guest-agent-dmg-staging.XXXXXX")
TEMP_DMG="$(mktemp -u "${DERIVED_FILE_DIR}/guest-agent-temp.XXXXXX").dmg"
trap 'rm -rf "${STAGING_DIR}" "${TEMP_DMG}"' EXIT

RAW_PREFIX="${DERIVED_FILE_DIR}/guest-agent-raw"
DMG_OUTPUT="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/KernovaMacOSAgent.dmg"
VERSION_OUTPUT="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/KernovaMacOSAgentVersion.txt"

ditto "${BUILT_PRODUCTS_DIR}/Kernova Guest Agent.app" "${STAGING_DIR}/Kernova Guest Agent.app"
cp "${SRCROOT}/KernovaMacOSAgent/install.command" "${STAGING_DIR}/install.command"
cp "${SRCROOT}/KernovaMacOSAgent/uninstall.command" "${STAGING_DIR}/uninstall.command"
chmod +x "${STAGING_DIR}/install.command" "${STAGING_DIR}/uninstall.command"
cp "${SRCROOT}/KernovaMacOSAgent/app.kernova.macosagent.plist" "${STAGING_DIR}/app.kernova.macosagent.plist"

mkdir -p "$(dirname "${DMG_OUTPUT}")"

# Create a UDRW DMG then convert to DVD/CD-R master (UDTO/.cdr).
# VZDiskImageStorageDeviceAttachment needs a format it can present as a
# USB block device — the .cdr export works reliably for guest-mountable volumes.
hdiutil create \
    -volname "Kernova Guest Agent" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDRW \
    "${TEMP_DMG}"
hdiutil convert "${TEMP_DMG}" -format UDTO -ov -o "${RAW_PREFIX}"
mv "${RAW_PREFIX}.cdr" "${DMG_OUTPUT}"

# Strip extended attributes that break code signing
xattr -cr "${DMG_OUTPUT}"

# Extract the agent's CFBundleShortVersionString from the app bundle's Info.plist
# and write a sidecar the host reads at runtime. Keeping the agent bundle as the
# single source of truth means the host cannot drift from what it actually ships.
AGENT_VERSION=$(plutil -extract CFBundleShortVersionString raw "${BUILT_PRODUCTS_DIR}/Kernova Guest Agent.app/Contents/Info.plist")
if [ -z "${AGENT_VERSION}" ]; then
    echo "error: Could not extract agent version from app bundle" >&2
    exit 1
fi
printf '%s' "${AGENT_VERSION}" > "${VERSION_OUTPUT}"
