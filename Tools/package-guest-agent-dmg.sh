#!/bin/bash
#
# package-guest-agent-dmg.sh — pack Kernova Guest Agent.app as the macOS agent's
# update payload, put the payload in Kernova.app's Resources, and stage it with
# the app and the install/uninstall commands into a guest-mountable raw disk
# image inside Kernova.app.
#
# The host serves the payload to installed agents and identifies them by its
# SHA-256; the disk's installer lands the same file, recording that hash, so a
# fresh install and an in-band update install one identity.
#
# Environment (exported by Xcode): SRCROOT, DERIVED_FILE_DIR,
# BUILT_PRODUCTS_DIR, CONTENTS_FOLDER_PATH.

set -euo pipefail

STAGING_DIR=$(mktemp -d "${DERIVED_FILE_DIR}/guest-agent-dmg-staging.XXXXXX")
trap 'rm -rf "${STAGING_DIR}"' EXIT

AGENT_APP="${BUILT_PRODUCTS_DIR}/Kernova Guest Agent.app"
RESOURCES="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
DMG_OUTPUT="${RESOURCES}/KernovaMacOSAgent.dmg"
PAYLOAD_OUTPUT="${RESOURCES}/GuestAgents/macos-arm64/agent.payload"

# The agent packs itself: the packer is its `pack-payload` command, which emits
# only the update profile every installed agent lands.
mkdir -p "$(dirname "${PAYLOAD_OUTPUT}")"
"${AGENT_APP}/Contents/MacOS/KernovaMacOSAgent" pack-payload "${AGENT_APP}" "${PAYLOAD_OUTPUT}"

ditto "${AGENT_APP}" "${STAGING_DIR}/Kernova Guest Agent.app"
cp "${PAYLOAD_OUTPUT}" "${STAGING_DIR}/agent.payload"
cp "${SRCROOT}/KernovaMacOSAgent/install.command" "${STAGING_DIR}/install.command"
cp "${SRCROOT}/KernovaMacOSAgent/uninstall.command" "${STAGING_DIR}/uninstall.command"
chmod +x "${STAGING_DIR}/install.command" "${STAGING_DIR}/uninstall.command"

mkdir -p "$(dirname "${DMG_OUTPUT}")"

# A raw image (GPT + APFS, no UDIF wrapper) is what
# VZDiskImageStorageDeviceAttachment presents to the guest as a USB block device.
diskutil image create from \
    --format RAW \
    --volumeName "Kernova Guest Agent" \
    "${STAGING_DIR}" "${DMG_OUTPUT}"

# Strip extended attributes that break code signing
xattr -cr "${DMG_OUTPUT}"
