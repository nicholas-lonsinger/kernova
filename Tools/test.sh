#!/usr/bin/env bash
# Tests the checkout: what `Tools/attest.sh record test` runs for `make test`.
# Runs the full test plan in Debug through Tools/xcodebuild.sh, with the flags
# every make target passes, then Tools/check-weak-links.sh on the Kernova.app
# that run built. Takes no arguments, so nothing a caller passes changes what a
# test record covers.

set -uo pipefail

[ $# -eq 0 ] || { echo 'usage: Tools/test.sh' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

Tools/xcodebuild.sh Debug test || exit
Tools/built-app.sh --check-weak-links Debug
