#!/usr/bin/env bash
# Prints where a build in this configuration (Tools/xcodebuild.sh) puts the
# Kernova app, read from xcodebuild's own build settings for it:
#
#     app=<path to Kernova.app>
#     binary=<path to its executable>
#
# Usage: Tools/built-app.sh [--check-weak-links] <configuration>
#   --check-weak-links   then runs Tools/check-weak-links.sh on that app
#
# Settings rather than a build's log: an up-to-date build need not log a link
# or signing command from which a product path could be recovered.

set -uo pipefail

check=0
if [ "${1:-}" = --check-weak-links ]; then
    check=1
    shift
fi
[ $# -eq 1 ] || { echo 'usage: Tools/built-app.sh [--check-weak-links] <configuration>' >&2; exit 2; }

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings=$("$tools/xcodebuild.sh" "$1" -showBuildSettings) || exit 1
paths=$(printf '%s\n' "$settings" | awk '
    /^Build settings for action / { app = ($0 ~ / and target Kernova:$/) }
    app && /^ *TARGET_BUILD_DIR = / { sub(/^ *TARGET_BUILD_DIR = /, ""); dir = $0 }
    app && /^ *FULL_PRODUCT_NAME = / { sub(/^ *FULL_PRODUCT_NAME = /, ""); product = $0 }
    app && /^ *EXECUTABLE_PATH = / { sub(/^ *EXECUTABLE_PATH = /, ""); executable = $0 }
    END {
        if (dir == "" || product == "" || executable == "") { print "error: could not resolve the Kernova app path" > "/dev/stderr"; exit 1 }
        print "app=" dir "/" product
        print "binary=" dir "/" executable
    }') || exit 1
printf '%s\n' "$paths"
[ "$check" -eq 1 ] || exit 0
exec "$tools/check-weak-links.sh" "$(sed -n 's/^app=//p' <<<"$paths")"
