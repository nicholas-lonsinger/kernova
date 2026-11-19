#!/usr/bin/env bash
# Tests the checkout: the command `make test` runs and records for
# `make attest`. Runs the full test plan, then Tools/check-weak-links.sh over
# the Kernova.app that same run built.
#
# Usage: Tools/test.sh <xcodebuild flag>...
#   the Makefile's XCODEBUILD_FLAGS; Tools/built-app.sh resolves the app from
#   the same flags.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

xcodebuild "$@" test || exit
paths=$(Tools/built-app.sh "$@") || exit 1
Tools/check-weak-links.sh "$(sed -n 's/^app=//p' <<<"$paths")"
