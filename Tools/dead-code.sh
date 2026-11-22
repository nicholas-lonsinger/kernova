#!/usr/bin/env bash
# The dead-code scan `make dead-code` runs, under the checkout's build lock and
# through `Tools/build-arenas.sh build`, which unregisters the apps it builds
# once it has exited, whatever the outcome, so a scan's build never wins the
# version election. Takes no arguments; the report goes to stdout, everything
# else to stderr.
#
# The macOS half reads .periphery.yml over one fixed arena per checkout.
# Periphery's own build would go to ~/Library/Caches/com.github.peripheryapp
# under a name hashed from its schemes in a Swift `Set`'s per-process order, a
# new multi-gigabyte arena most runs; the checkout's other arenas index one
# scheme or none, and the GUI's is no single build's index. The build flags are
# Periphery 3.x's own plus the compilation cache off: a compile the cache
# serves writes no index unit, leaving the unit an earlier compile wrote — after
# a revert, a cached scan reported 27 findings in code that no longer existed
# (Xcode 27.1). Each scheme is built for testing, so the one index serves both
# views — the full scan, and the production scan with every target only tests
# reach excluded — and the bundle written from it holds both and that index's
# declaration sites. With the Ubuntu SDK installed, Tools/dead-code-linux.sh
# writes the Linux bundle beside it and the report combines the two, as
# .github/workflows/dead-code.yml does; without it the report covers macOS
# alone and names what installs the rest.

set -uo pipefail

[ $# -eq 0 ] || { echo 'usage: Tools/dead-code.sh' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
root=$(pwd -P)

# shellcheck source=lib/xcodebuild-flags.sh
. Tools/lib/xcodebuild-flags.sh
schemes=(Kernova KernovaMacOSAgent KernovaRelaunchHelper KernovaCLI KernovaBench)
arena=$kernova_dead_code_derived_data
macos_bundle=$arena/Report/macos
linux_bundle=$arena/Report/linux
raw=$arena/Report/raw
project_flags=()
while IFS= read -r flag; do project_flags+=("$flag"); done < <(xcodebuild_project_flags)

periphery=$(Tools/install-periphery.sh) || exit 1
indexutil=$(Tools/install-periphery.sh --indexutil-export) || exit 1
dead_code=$(Tools/install-dead-code-tool.sh dead-code) || exit 1
sources=$(Tools/install-dead-code-tool.sh dead-code-sources) || exit 1
mkdir -p "$raw" || exit 1
"$dead_code" test-only-targets --project "$kernova_project" >"$raw/test-only-targets.txt" || exit 1
for scheme in "${schemes[@]}"; do
    xcodebuild "${project_flags[@]}" -scheme "$scheme" -destination "$kernova_destination" \
        -derivedDataPath "$arena" -parallelizeTargets -quiet \
        build-for-testing \
        CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf \
        COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES \
        COMPILATION_CACHE_ENABLE_CACHING=NO >&2 || exit 1
done
"$sources" bundle --root "$root" --base "$root" --periphery "$periphery" \
    --store "$arena/Index.noindex/DataStore" --indexutil-export "$indexutil" \
    --test-only-targets "$raw/test-only-targets.txt" --output "$macos_bundle" \
    -- --project "$kernova_project" --schemes "${schemes[@]}" || exit 1

# shellcheck source=lib/linux-swift.sh
. Tools/lib/linux-swift.sh
missing=$(ubuntu_sdk_missing "$(pinned_swift_version)")
if [ -n "$missing" ]; then
    exec "$dead_code" report --platform "macos=$macos_bundle" \
        --remedy "The Linux half builds with $missing, which is not installed: run \`make ubuntu-sdk\` once, and \`make dead-code\` then scans both."
fi
Tools/dead-code-linux.sh "$raw/test-only-targets.txt" "$linux_bundle" >&2 || exit 1
exec "$dead_code" report --platform "macos=$macos_bundle" --platform "linux=$linux_bundle"
