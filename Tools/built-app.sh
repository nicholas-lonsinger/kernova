#!/usr/bin/env bash
# Prints where a build with these xcodebuild flags puts the Kernova app, read
# from xcodebuild's own build settings for them:
#
#     app=<path to Kernova.app>
#     binary=<path to its executable>
#
# Usage: Tools/built-app.sh <xcodebuild flag>...
#
# Settings rather than a build's log: an up-to-date build need not log a link
# or signing command from which a product path could be recovered.

set -uo pipefail

settings=$(xcodebuild "$@" -showBuildSettings) || exit 1
printf '%s\n' "$settings" | awk '
    /^Build settings for action / { app = ($0 ~ / and target Kernova:$/) }
    app && /^ *TARGET_BUILD_DIR = / { sub(/^ *TARGET_BUILD_DIR = /, ""); dir = $0 }
    app && /^ *FULL_PRODUCT_NAME = / { sub(/^ *FULL_PRODUCT_NAME = /, ""); product = $0 }
    app && /^ *EXECUTABLE_PATH = / { sub(/^ *EXECUTABLE_PATH = /, ""); executable = $0 }
    END {
        if (dir == "" || product == "" || executable == "") { print "error: could not resolve the Kernova app path" > "/dev/stderr"; exit 1 }
        print "app=" dir "/" product
        print "binary=" dir "/" executable
    }'
