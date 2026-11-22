#!/usr/bin/env bash
# Runs one xcodebuild action on the app from the checkout's root, with the
# flags Tools/lib/xcodebuild-flags.sh gives every build and test of it in the
# given configuration, then the arguments:
#
#     Tools/xcodebuild.sh <configuration> <action> [<xcodebuild argument>...]
#
# <action> is build, build-for-testing, test, test-without-building or
# -showBuildSettings. The flags reach xcodebuild as one argument each, never
# through a shell or make's word splitting: a build setting's value holds
# `$(…)` and spaces.

set -uo pipefail

[ $# -ge 2 ] || { echo 'usage: Tools/xcodebuild.sh <configuration> <action> [<xcodebuild argument>...]' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/xcodebuild-flags.sh
. Tools/lib/xcodebuild-flags.sh
flags=()
while IFS= read -r flag; do flags+=("$flag"); done < <(xcodebuild_flags "$1" "$2")
shift 2
exec xcodebuild "${flags[@]}" "$@"
