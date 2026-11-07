#!/usr/bin/env bash
# Installs the pinned Periphery release the dead-code scan runs on, and the
# `indexutil-export` the combined scan reads each platform's index with.
#
# `make dead-code`, `Tools/dead-code-linux.sh` and
# `.github/workflows/dead-code.yml` all resolve the binaries through this
# script, so a local scan and the CI scan are the same scan. Idempotent: an
# installed binary is reported, never rebuilt.
#
# peripheryapp/periphery was archived on 2026-08-12 and its final release is
# 3.8.0; Homebrew's formula is deprecated and is disabled on 2027-08-12. On
# macOS the binary comes from the release zip, into ~/Library/Caches (it is
# re-downloadable, and no step here needs sudo). The release ships no Linux
# binary, so on Linux it is built from the tag, linking the toolchain's
# libIndexStore.so: a build serves only the Swift toolchain it was built with.
#
# `indexutil-export` is built on every platform from swift-index-store at the
# revision Periphery's own Package.resolved pins, so it reads the index format
# Periphery reads.
#
# Usage: Tools/install-periphery.sh [--indexutil-export | --version | --path]
#   (no flag)           install Periphery when absent, then print its path
#   --indexutil-export  install indexutil-export when absent, then print its path
#   --version           print the pinned version
#   --path              print Periphery's path, installing nothing
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.

set -euo pipefail

PERIPHERY_VERSION='3.8.0'
if [ "$(uname -s)" = Darwin ]; then
    INSTALL_DIR="$HOME/Library/Caches/kernova-dev/periphery-$PERIPHERY_VERSION"
else
    INSTALL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kernova-dev/periphery-$PERIPHERY_VERSION"
fi
BINARY="$INSTALL_DIR/periphery"
INDEXUTIL="$INSTALL_DIR/indexutil-export"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

want=periphery
case "${1:-}" in
    --version)
        printf '%s\n' "$PERIPHERY_VERSION"
        exit 0
        ;;
    --path)
        printf '%s\n' "$BINARY"
        exit 0
        ;;
    --indexutil-export) want=indexutil ;;
    '') ;;
    *)
        printf 'install-periphery.sh: unknown option %s — expected --indexutil-export, --version or --path\n' "$1" >&2
        exit 2
        ;;
esac

target="$BINARY"
[ "$want" = indexutil ] && target="$INDEXUTIL"
if [ -x "$target" ]; then
    printf '%s\n' "$target"
    exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$INSTALL_DIR"

# Periphery's source at the pinned tag, in $tmp_dir/periphery.
periphery_source() {
    detail "Cloning Periphery $PERIPHERY_VERSION" >&2
    git clone --quiet --depth 1 --branch "$PERIPHERY_VERSION" \
        https://github.com/peripheryapp/periphery.git "$tmp_dir/periphery" >&2
}

if [ "$want" = indexutil ]; then
    periphery_source
    revision=$(awk '/"identity" : "swift-index-store"/ { found = 1 }
        found && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$tmp_dir/periphery/Package.resolved")
    if [ -z "$revision" ]; then
        printf 'install-periphery.sh: Periphery %s pins no swift-index-store revision\n' "$PERIPHERY_VERSION" >&2
        exit 1
    fi
    detail "Building indexutil-export at swift-index-store $revision" >&2
    source_dir="$tmp_dir/swift-index-store"
    git init --quiet "$source_dir"
    git -C "$source_dir" fetch --quiet --depth 1 https://github.com/ileitch/swift-index-store "$revision" >&2
    git -C "$source_dir" checkout --quiet FETCH_HEAD
    swift build -c release --package-path "$source_dir" --product indexutil-export >&2
    cp "$(swift build -c release --package-path "$source_dir" --show-bin-path)/indexutil-export" "$INDEXUTIL"
    pass "indexutil-export installed" >&2
    value "$INDEXUTIL" >&2
    printf '%s\n' "$INDEXUTIL"
    exit 0
fi

if [ "$(uname -s)" = Darwin ]; then
    url="https://github.com/peripheryapp/periphery/releases/download/${PERIPHERY_VERSION}/periphery-${PERIPHERY_VERSION}.zip"
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
    mv "$tmp_dir/extract/periphery" "$tmp_dir/extract/libIndexStore.dylib" "$INSTALL_DIR/"
else
    periphery_source
    detail "Building Periphery $PERIPHERY_VERSION (minutes)" >&2
    swift build -c release --package-path "$tmp_dir/periphery" --product periphery >&2
    cp "$(swift build -c release --package-path "$tmp_dir/periphery" --show-bin-path)/periphery" "$BINARY"
fi
chmod +x "$BINARY"

if ! installed_version="$("$BINARY" version 2>&1)"; then
    printf 'install-periphery.sh: the installed binary does not run: %s\n' "$installed_version" >&2
    exit 1
fi

pass "Periphery $installed_version installed" >&2
value "$BINARY" >&2
printf '%s\n' "$BINARY"
