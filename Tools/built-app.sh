#!/usr/bin/env bash
# Prints where a build in this configuration (Tools/xcodebuild.sh) put the
# Kernova app, under the derived data Tools/lib/xcodebuild-flags.sh names:
#
#     app=<path to Kernova.app>
#     binary=<path to its executable>
#
# Usage: Tools/built-app.sh [--check-weak-links] <configuration>
#   --check-weak-links   then runs Tools/check-weak-links.sh on that app

set -uo pipefail

check=0
if [ "${1:-}" = --check-weak-links ]; then
    check=1
    shift
fi
[ $# -eq 1 ] || { echo 'usage: Tools/built-app.sh [--check-weak-links] <configuration>' >&2; exit 2; }

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/xcodebuild-flags.sh
. "$tools/lib/xcodebuild-flags.sh"
app="$kernova_checkout/$kernova_derived_data/Build/Products/$1/Kernova.app"
[ -d "$app" ] || { echo "error: no Kernova.app at $app" >&2; exit 1; }
printf 'app=%s\nbinary=%s\n' "$app" "$app/Contents/MacOS/Kernova"
[ "$check" -eq 1 ] || exit 0
exec "$tools/check-weak-links.sh" "$app"
