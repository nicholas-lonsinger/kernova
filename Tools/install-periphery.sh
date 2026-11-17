#!/usr/bin/env bash
# Installs the dead-code scan's Periphery — the pinned release built from
# source with Tools/periphery.patch applied — and the `indexutil-export` the
# combined scan reads each platform's index with.
#
# `make dead-code`, `Tools/dead-code-linux.sh` and
# `.github/workflows/dead-code.yml` all resolve the binaries through this
# script, so a local scan and the CI scan are the same scan. Idempotent: an
# installed binary is reported, never rebuilt.
#
# peripheryapp/periphery was archived on 2026-08-12 at its final open-source
# release, 3.8.0, so a defect in it is fixed in that patch. Every platform
# builds the tag with the `swift` on PATH, into ~/Library/Caches on macOS (it
# is rebuildable, and no step here needs sudo). On Linux the build links the
# toolchain's libIndexStore.so: a build serves only the Swift toolchain it was
# built with.
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

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$tools_dir/lib/output.sh"

PERIPHERY_VERSION='3.8.0'
PATCH="$tools_dir/periphery.patch"
patch_checksum="$(cksum <"$PATCH" | cut -d ' ' -f 1)"
if [ "$(uname -s)" = Darwin ]; then
    cache_dir="$HOME/Library/Caches/kernova-dev"
else
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/kernova-dev"
fi
INSTALL_DIR="$cache_dir/periphery-$PERIPHERY_VERSION-$patch_checksum"
BINARY="$INSTALL_DIR/periphery"
INDEXUTIL="$INSTALL_DIR/indexutil-export"

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

detail "Cloning Periphery $PERIPHERY_VERSION" >&2
git clone --quiet --depth 1 --branch "$PERIPHERY_VERSION" \
    https://github.com/peripheryapp/periphery.git "$tmp_dir/periphery" >&2

if [ "$want" = indexutil ]; then
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

if ! git -C "$tmp_dir/periphery" apply "$PATCH" >&2; then
    printf 'install-periphery.sh: %s does not apply to Periphery %s\n' "$PATCH" "$PERIPHERY_VERSION" >&2
    exit 1
fi
detail "Building Periphery $PERIPHERY_VERSION with $(basename "$PATCH") (minutes)" >&2
swift build -c release --package-path "$tmp_dir/periphery" --product periphery >&2
cp "$(swift build -c release --package-path "$tmp_dir/periphery" --show-bin-path)/periphery" "$BINARY"

if ! installed_version="$("$BINARY" version 2>&1)"; then
    printf 'install-periphery.sh: the installed binary does not run: %s\n' "$installed_version" >&2
    exit 1
fi

pass "Periphery $installed_version installed" >&2
value "$BINARY" >&2
printf '%s\n' "$BINARY"
