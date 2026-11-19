# The flags every xcodebuild build and test of the app passes, for the
# Makefile's targets and Tools/test.sh. Sourced, never run.

# shellcheck shell=bash

# shellcheck disable=SC2034 # read by the Makefile
kernova_project=Kernova.xcodeproj
# shellcheck disable=SC2034
kernova_scheme=Kernova
# shellcheck disable=SC2034
kernova_destination=platform=macOS

# xcodebuild_project_flags [<project>] — one flag per line: the project
# (Kernova's by default), and every xcodebuild of it builds the packages the
# tracked Package.resolved pins, or fails.
xcodebuild_project_flags() {
    printf '%s\n' -project "${1:-$kernova_project}" -onlyUsePackageVersionsFromResolvedFile
}

# xcodebuild_flags <configuration> — one flag per line. The configuration is
# passed explicitly rather than left to the scheme's per-action default. With
# CI set, the CI-only settings follow; `CI=1 make test` reproduces a CI build.
xcodebuild_flags() {
    xcodebuild_project_flags
    printf '%s\n' -scheme "$kernova_scheme" \
        -destination "$kernova_destination" -configuration "$1"
    [ -n "${CI:-}" ] || return 0
    # -derivedDataPath only under CI, so artifacts land at a fixed path: on a
    # dev machine a terminal build shares the Xcode GUI's arena. The flag, even
    # at the identical resolved path, records a different arena identity in the
    # build description, and every CLI↔GUI switch then rebuilds the whole graph
    # both ways (measured in Relative mode).
    #
    # The index store serves an editor CI does not have. The compilation cache
    # is on project-wide in Config/Base.xcconfig and repeated here because a
    # package target never reads a project xcconfig. The limit is below any
    # build's output, so every build rolls the store over into a fresh
    # generation that holds exactly what that build produced or looked up — the
    # workflow prunes the generation left behind and saves the rest.
    printf '%s\n' -derivedDataPath DerivedData/Kernova \
        COMPILER_INDEX_STORE_ENABLE=NO \
        COMPILATION_CACHE_ENABLE_CACHING=YES \
        COMPILATION_CACHE_LIMIT_SIZE=1M
}
