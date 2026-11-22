#!/usr/bin/env bash
# Installs the dead-code scan's Periphery — the pinned release built from
# source with Tools/periphery.patch applied — and the `indexutil-export` the
# combined scan reads each platform's index with, together, into the
# machine's tool cache (Tools/lib/tool-cache.sh).
#
# `make dead-code`, `Tools/dead-code-linux.sh` and
# `.github/workflows/dead-code.yml` all resolve the binaries through this
# script, so a local scan and the CI scan are the same scan.
#
# peripheryapp/periphery was archived on 2026-08-12 at its final open-source
# release, 3.8.0, so a defect in it is fixed in that patch. Every platform
# builds the tag with the `swift` on PATH, linking that toolchain's
# libIndexStore — on macOS by an absolute path into Xcode — so a build serves
# only the toolchain it was built with.
#
# `indexutil-export` is built from swift-index-store at the revision
# Periphery's own Package.resolved pins, so it reads the index format
# Periphery reads.
#
# Usage: Tools/install-periphery.sh [--indexutil-export | --version | --path]
#   (no flag)           install both when absent, then print Periphery's path
#   --indexutil-export  install both when absent, then print indexutil-export's path
#   --version           print the pinned version
#   --path              print Periphery's path, installing nothing
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.
#
# pin: git https://github.com/peripheryapp/periphery.git PERIPHERY_VERSION

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/output.sh
. "$root/Tools/lib/output.sh"
# shellcheck source=lib/tool-cache.sh
. "$root/Tools/lib/tool-cache.sh"

PERIPHERY_VERSION='3.8.0'
inputs=(periphery "$PERIPHERY_VERSION" -- Tools/install-periphery.sh Tools/periphery.patch)

build_periphery() {
    local entry=$1 source=$2/periphery index_store=$2/swift-index-store revision
    detail "Cloning Periphery $PERIPHERY_VERSION" >&2
    git clone --quiet --depth 1 --branch "$PERIPHERY_VERSION" \
        https://github.com/peripheryapp/periphery.git "$source" >&2
    if ! git -C "$source" apply "$root/Tools/periphery.patch" >&2; then
        printf 'install-periphery.sh: Tools/periphery.patch does not apply to Periphery %s\n' "$PERIPHERY_VERSION" >&2
        return 1
    fi
    detail "Building Periphery $PERIPHERY_VERSION with periphery.patch (minutes)" >&2
    local build=(swift build -c release --package-path "$source" --only-use-versions-from-resolved-file)
    "${build[@]}" --product periphery >&2
    cp "$("${build[@]}" --show-bin-path)/periphery" "$entry/"

    revision=$(awk '/"identity" : "swift-index-store"/ { found = 1 }
        found && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$source/Package.resolved")
    if [ -z "$revision" ]; then
        printf 'install-periphery.sh: Periphery %s pins no swift-index-store revision\n' "$PERIPHERY_VERSION" >&2
        return 1
    fi
    detail "Building indexutil-export at swift-index-store $revision" >&2
    git init --quiet "$index_store"
    git -C "$index_store" fetch --quiet --depth 1 https://github.com/ileitch/swift-index-store "$revision" >&2
    git -C "$index_store" checkout --quiet FETCH_HEAD
    swift build -c release --package-path "$index_store" --product indexutil-export >&2
    cp "$(swift build -c release --package-path "$index_store" --show-bin-path)/indexutil-export" "$entry/"
}

# Periphery reports its version; indexutil-export, with no arguments, prints
# its usage and exits 1.
verify_periphery() {
    local version usage
    if ! version=$("$1/periphery" version 2>&1) || [ "$version" != "$PERIPHERY_VERSION" ]; then
        printf 'install-periphery.sh: the built periphery reports %s\n' "$version" >&2
        return 1
    fi
    if usage=$("$1/indexutil-export" 2>&1) || [[ "$usage" != 'Usage: indexutil export'* ]]; then
        printf 'install-periphery.sh: the built indexutil-export prints %s\n' "$usage" >&2
        return 1
    fi
}

binary=periphery
case "${1:-}" in
    --version)
        printf '%s\n' "$PERIPHERY_VERSION"
        exit 0
        ;;
    --path)
        printf '%s/periphery\n' "$(tool_dir "${inputs[@]}")"
        exit 0
        ;;
    --indexutil-export) binary=indexutil-export ;;
    '') ;;
    *)
        printf 'install-periphery.sh: unknown option %s — expected --indexutil-export, --version or --path\n' "$1" >&2
        exit 2
        ;;
esac

dir=$(tool_install build_periphery verify_periphery "${inputs[@]}")
printf '%s/%s\n' "$dir" "$binary"
