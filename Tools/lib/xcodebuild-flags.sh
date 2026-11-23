# The flags every xcodebuild build and test of the app passes
# (Tools/xcodebuild.sh), and where those builds write. Sourced, never run.

# shellcheck shell=bash

kernova_project=Kernova.xcodeproj
kernova_scheme=Kernova
kernova_destination=platform=macOS
kernova_checkout=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# The checkout's build arenas, relative to its root: these flags', and the
# dead-code scan's. Xcode's Relative derived-data location builds the GUI's
# into `DerivedData/Kernova` by default, which neither is.
kernova_derived_data_root=DerivedData
kernova_derived_data=$kernova_derived_data_root/Make
# shellcheck disable=SC2034 # read by Tools/dead-code.sh
kernova_dead_code_derived_data=$kernova_derived_data_root/Periphery
# The compilation cache store these flags build with, and its size limit. Past
# the limit a build starts a new generation and keeps the previous one as a
# read-through fallback; a later build deletes the older ones, so three can be
# on disk in between (Xcode 27.2). Outside CI every checkout of the user's
# shares one store, which nothing but these flags writes: the Xcode app keeps
# Xcode's own (Config/Base.xcconfig). Under CI the store is inside the
# checkout, so no CI-mode run reaches the shared one, and its limit is below
# any build's output: every build rolls the store over into a fresh generation
# holding exactly what that build produced or looked up, which the workflow
# prunes down to and saves.
if [ -n "${CI:-}" ]; then
    kernova_compilation_cache=$kernova_checkout/$kernova_derived_data_root/CompilationCache.noindex
    kernova_compilation_cache_limit=1M
else
    kernova_compilation_cache=$HOME/Library/Developer/Kernova/CompilationCache.noindex
    kernova_compilation_cache_limit=16G
fi
# What every path under the checkout compiles as: what a source location, a
# `#filePath` and the debug info of a build name in place of the checkout.
# lldb shows a build's source once told `settings set target.source-map /^src
# <checkout>`.
kernova_source_placeholder=/^src

# xcodebuild_project_flags [<project>] — one flag per line: the project
# (Kernova's by default), and every xcodebuild of it builds the packages the
# tracked Package.resolved pins, or fails.
xcodebuild_project_flags() {
    printf '%s\n' -project "${1:-$kernova_project}" -onlyUsePackageVersionsFromResolvedFile
}

# xcodebuild_flags <configuration> <action> — one flag per line, for an
# xcodebuild run of <action> from the checkout's root, the action last. The
# configuration is passed explicitly rather than left to the scheme's
# per-action default. `CI=1 make test` reproduces a CI build.
#
# Every target compiles each path under the checkout as the placeholder, so a
# compilation's cache key holds no checkout path and one checkout's compile
# serves every other on the machine. The settings are on the command line,
# which the Xcode app's builds never see. The checkout is mapped under both of
# its spellings: Xcode's own, which drops a leading /private, names the
# project's files, and the resolved one names the packages' (Xcode 27.2). The
# project mapping is off: a package target's project directory is
# its package, not the checkout.
#
# A compile the cache serves writes no index unit, and the others' units name
# the placeholder, so no build here writes an index store. A test gathers no
# code coverage: its report names the placeholder, and lists no source file.
xcodebuild_flags() {
    local mappings
    mappings="\"\$(WORKSPACE_DIR:dir:standardizepath)=$kernova_source_placeholder\" \"$kernova_checkout=$kernova_source_placeholder\""
    # xcodebuild refuses the coverage flag on any other action.
    case "$2" in
        build-for-testing | test | test-without-building) printf '%s\n' -enableCodeCoverage NO ;;
    esac
    xcodebuild_project_flags
    printf '%s\n' -scheme "$kernova_scheme" -destination "$kernova_destination" -configuration "$1" \
        -derivedDataPath "$kernova_derived_data" \
        COMPILER_INDEX_STORE_ENABLE=NO \
        COMPILATION_CACHE_ENABLE_CACHING=YES \
        "COMPILATION_CACHE_CAS_PATH=$kernova_compilation_cache" \
        "COMPILATION_CACHE_LIMIT_SIZE=$kernova_compilation_cache_limit" \
        SWIFT_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES \
        SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=NO CLANG_ENABLE_PROJECT_PREFIX_MAPPING=NO \
        "SWIFT_OTHER_PREFIX_MAPPINGS=$mappings" "CLANG_OTHER_PREFIX_MAPPINGS=$mappings" \
        "$2"
}
