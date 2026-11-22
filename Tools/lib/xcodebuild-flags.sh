# The flags every xcodebuild build and test of the app passes
# (Tools/xcodebuild.sh), and where those builds write. Sourced, never run.

# shellcheck shell=bash

# shellcheck disable=SC2034 # read by the Makefile
kernova_project=Kernova.xcodeproj
# shellcheck disable=SC2034
kernova_scheme=Kernova
# shellcheck disable=SC2034
kernova_destination=platform=macOS
# The checkout's build arenas, relative to its root: these flags' and the
# dead-code scan's. Xcode's Relative derived-data location builds the GUI's
# into `DerivedData/Kernova` by default, which neither is.
kernova_derived_data_root=DerivedData
kernova_derived_data=$kernova_derived_data_root/Make
# The compilation cache store every checkout's builds share.
kernova_compilation_cache=$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex
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
# per-action default. With CI set, the CI-only settings follow; `CI=1 make
# test` reproduces a CI build.
#
# Every target compiles each path under the checkout as the placeholder, so a
# compilation's cache key holds no checkout path and one checkout's compile
# serves every other on the machine, from the one store each user has. The
# settings are on the command line because a package target reads no project
# xcconfig. The checkout is mapped under both of its spellings: Xcode's own,
# which drops a leading /private, names the project's files, and the resolved
# one names the packages' (Xcode 27.2). The project mapping is off: a package
# target's project directory is its package, not the checkout.
#
# A compile the cache serves writes no index unit, and the others' units name
# the placeholder, so no build here writes an index store. A test gathers no
# code coverage: its report names the placeholder, and lists no source file.
xcodebuild_flags() {
    local root mappings
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || return 1
    mappings="\"\$(WORKSPACE_DIR:dir:standardizepath)=$kernova_source_placeholder\" \"$root=$kernova_source_placeholder\""
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
        SWIFT_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES \
        SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=NO CLANG_ENABLE_PROJECT_PREFIX_MAPPING=NO \
        "SWIFT_OTHER_PREFIX_MAPPINGS=$mappings" "CLANG_OTHER_PREFIX_MAPPINGS=$mappings"
    if [ -z "${CI:-}" ]; then
        # Past the limit the store rolls over into a new generation and keeps
        # the previous one as a read-through fallback, so on disk it holds up
        # to two generations.
        printf '%s\n' COMPILATION_CACHE_LIMIT_SIZE=16G
    else
        # The limit is below any build's output, so every build rolls the
        # store over into a fresh generation that holds exactly what that build
        # produced or looked up — the workflow prunes the generation left
        # behind and saves the rest.
        printf '%s\n' COMPILATION_CACHE_LIMIT_SIZE=1M
    fi
    printf '%s\n' "$2"
}
