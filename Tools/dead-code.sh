#!/usr/bin/env bash
# The dead-code scan `make dead-code` runs under the checkout's build lock:
# whichever Periphery is on PATH, over one macOS Debug build of the Kernova and
# KernovaBench schemes, scanned twice — whole, then without the targets only
# tests reach. Prints what nothing uses, then what only tests use; the build's
# output goes to stderr. Takes no arguments. Code only Linux compiles goes
# unscanned, and `#if DEBUG` test hooks list as used only by tests.
#
# The build writes its own index store into one fixed arena with the
# compilation cache off: a compile the cache serves writes no index unit and
# leaves the unit an earlier compile wrote — after a revert, a cached scan
# reported 27 findings in code that no longer existed (Xcode 27.1).

set -uo pipefail

[ $# -eq 0 ] || { echo 'usage: Tools/dead-code.sh' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
command -v periphery >/dev/null || { echo 'dead-code: no periphery on PATH: brew install periphery' >&2; exit 1; }

# shellcheck source=lib/xcodebuild-flags.sh
. Tools/lib/xcodebuild-flags.sh
arena=$kernova_dead_code_derived_data
project_flags=()
while IFS= read -r flag; do project_flags+=("$flag"); done < <(xcodebuild_project_flags)

# Xcode registers each app it builds with Launch Services, where a copy could
# launch in place of the installed app, so the scan's are unregistered however
# the run ends.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap 'find "$arena/Build/Products" -name "*.app" -type d -exec "$lsregister" -u {} \; 2>/dev/null' EXIT

for scheme in Kernova KernovaBench; do
    xcodebuild "${project_flags[@]}" -scheme "$scheme" -destination "$kernova_destination" \
        -derivedDataPath "$arena" -quiet build-for-testing \
        CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf \
        COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
        COMPILATION_CACHE_ENABLE_CACHING=NO >&2 || exit 1
done

# The test bundles, and the targets only they link.
test_only=(KernovaTestHost KernovaAgentSimulation)
for dir in *Tests Kernova*/Tests/* Kernova*/Sources/*TestSupport; do test_only+=("${dir##*/}"); done

scan=(periphery scan --project "$kernova_project" --schemes "$kernova_scheme" --skip-schemes-validation
    --index-store-path "$arena/Index.noindex/DataStore" --relative-results --quiet --disable-update-check)
echo 'Unused:'
"${scan[@]}" --write-baseline "$arena/unused.json" || exit 1
printf '\nReached only by tests:\n'
"${scan[@]}" --baseline "$arena/unused.json" --exclude-targets "${test_only[@]}"
