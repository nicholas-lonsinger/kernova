#!/usr/bin/env bash
# Installs the pinned Periphery release the dead-code scan runs on.
#
# `make dead-code` and `.github/workflows/dead-code.yml` both resolve the
# binary through this script, so a local scan and the CI scan are the same
# scan. Idempotent: an installed binary is reported, never re-downloaded.
#
# peripheryapp/periphery was archived on 2026-08-12 and its final release is
# 3.8.0; Homebrew's formula is deprecated and is disabled on 2027-08-12. The
# binary therefore comes from the release zip, into ~/Library/Caches (it is
# re-downloadable, and no step here needs sudo).
#
# Usage: Tools/install-periphery.sh [--version | --path]
#   (no flag)  install when absent, then print the binary path
#   --version  print the pinned version
#   --path     print the binary path, installing nothing
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.

set -euo pipefail

PERIPHERY_VERSION='3.8.0'
INSTALL_DIR="$HOME/Library/Caches/kernova-dev/periphery-$PERIPHERY_VERSION"
BINARY="$INSTALL_DIR/periphery"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

case "${1:-}" in
    --version)
        printf '%s\n' "$PERIPHERY_VERSION"
        exit 0
        ;;
    --path)
        printf '%s\n' "$BINARY"
        exit 0
        ;;
    '') ;;
    *)
        printf 'install-periphery.sh: unknown option %s — expected --version or --path\n' "$1" >&2
        exit 2
        ;;
esac

if [ -x "$BINARY" ]; then
    printf '%s\n' "$BINARY"
    exit 0
fi

url="https://github.com/peripheryapp/periphery/releases/download/${PERIPHERY_VERSION}/periphery-${PERIPHERY_VERSION}.zip"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

detail "Downloading Periphery $PERIPHERY_VERSION" >&2
if ! curl -fsSL "$url" -o "$tmp_dir/periphery.zip"; then
    printf 'install-periphery.sh: download failed: %s\n' "$url" >&2
    exit 1
fi

if ! unzip -oq "$tmp_dir/periphery.zip" -d "$tmp_dir/extract"; then
    printf 'install-periphery.sh: could not unzip %s\n' "$tmp_dir/periphery.zip" >&2
    exit 1
fi

# The binary loads libIndexStore.dylib through @rpath, so the two files live
# side by side in the install directory.
mkdir -p "$INSTALL_DIR"
mv "$tmp_dir/extract/periphery" "$tmp_dir/extract/libIndexStore.dylib" "$INSTALL_DIR/"
chmod +x "$BINARY"

if ! installed_version="$("$BINARY" version 2>&1)"; then
    printf 'install-periphery.sh: the installed binary does not run: %s\n' "$installed_version" >&2
    exit 1
fi

pass "Periphery $installed_version installed" >&2
value "$BINARY" >&2
printf '%s\n' "$BINARY"
