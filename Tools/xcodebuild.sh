#!/usr/bin/env bash
# Runs one xcodebuild of the app from the checkout's root, under the
# checkout's build lock (Tools/build-lock.sh):
#
#     Tools/xcodebuild.sh <configuration> <action> [<xcodebuild argument>...]
#     Tools/xcodebuild.sh -resolvePackageDependencies
#
# The first runs <action> — build, build-for-testing, test,
# test-without-building or -showBuildSettings — with the flags
# Tools/lib/xcodebuild-flags.sh gives every build and test of it in the given
# configuration, then the arguments; the second rewrites the tracked package
# pins. The flags reach xcodebuild as one argument each, never through a shell
# or make's word splitting: a build setting's value holds `$(…)` and spaces.

set -uo pipefail

usage() {
    echo 'usage: Tools/xcodebuild.sh <configuration> <action> [<xcodebuild argument>...] | -resolvePackageDependencies' >&2
    exit 2
}
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/xcodebuild-flags.sh
. Tools/lib/xcodebuild-flags.sh
if [ "${1:-}" = -resolvePackageDependencies ]; then
    [ $# -eq 1 ] || usage
    command=(xcodebuild -project "$kernova_project" -derivedDataPath "$kernova_derived_data" -resolvePackageDependencies)
else
    [ $# -ge 2 ] || usage
    command=(xcodebuild)
    while IFS= read -r flag; do command+=("$flag"); done < <(xcodebuild_flags "$1" "$2")
    shift 2
    command+=("$@")
fi
exec Tools/build-lock.sh "${command[@]}"
