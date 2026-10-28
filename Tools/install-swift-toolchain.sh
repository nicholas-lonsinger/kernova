#!/usr/bin/env bash
# Installs the swift.org toolchain `.swift-version` names, and the Static Linux
# SDK built for it, through swiftly. Xcode's toolchain cannot target Linux, and
# an SDK works only with the toolchain release it was built for, so the two are
# pinned together here.
#
# swiftly itself comes from swift.org's signed package, installed into the
# user's home with no change to the shell profile, so `swift` on PATH stays
# Xcode's and this toolchain is reached only through `swiftly run`. Idempotent:
# what is installed is reported, never re-downloaded.
#
# Usage: Tools/install-swift-toolchain.sh
#   installs what is absent, then prints the swiftly binary's path
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

# shellcheck source=lib/static-linux-sdk.sh
. "$lib_dir/lib/static-linux-sdk.sh"

swift_version="$(tr -d '[:space:]' <.swift-version)"
swiftly="$(swiftly_binary)"

if [ ! -x "$swiftly" ]; then
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    detail 'Downloading swiftly' >&2
    curl -fsSL https://download.swift.org/swiftly/darwin/swiftly.pkg -o "$tmp_dir/swiftly.pkg"
    installer -pkg "$tmp_dir/swiftly.pkg" -target CurrentUserHomeDirectory >&2
    "$swiftly" init --no-modify-profile --skip-install --quiet-shell-followup --assume-yes >&2
fi

"$swiftly" install "$swift_version" --assume-yes >&2

sdk_id="$(static_sdk_id "$swift_version")"
installed_sdks="$("$swiftly" run swift sdk list "+$swift_version")"
if ! grep -qxF "$sdk_id" <<<"$installed_sdks"; then
    "$swiftly" run swift sdk install "$(static_sdk_url "$swift_version")" \
        --checksum "$STATIC_SDK_CHECKSUM" "+$swift_version" >&2
fi

pass "Swift $swift_version and $sdk_id installed" >&2
value "$swiftly" >&2
printf '%s\n' "$swiftly"
