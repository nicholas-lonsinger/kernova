# What a DerivedData build arena records about the checkout it belongs to.
# Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/arena-records.sh"

# shellcheck shell=bash

# arena_recorded_project <dir> — the .xcodeproj an arena root records, printed
# on stdout, or return 1 when <dir> is not an arena root that records one.
#
# Xcode writes that path in two independent places, and an arena can hold either
# one alone. info.plist's WorkspacePath comes with the first build; an arena
# that has only ever resolved packages never gets one, and then the PIF cache's
# workspace object is the sole record, naming the .xcodeproj's
# project.xcworkspace. Reading both is what makes attribution independent of
# whether a build ever ran in the arena.
arena_recorded_project() {
    local dir=$1 ws record
    if [ -f "$dir/info.plist" ]; then
        ws=$(plutil -extract WorkspacePath raw "$dir/info.plist" -o - 2>/dev/null) || ws=''
        if [ -n "$ws" ]; then
            printf '%s' "$ws"
            return 0
        fi
    fi
    # The records are keyed by a hash of the same workspace path, so whichever
    # one reads first answers for all of them.
    for record in "$dir"/Build/Intermediates.noindex/XCBuildData/PIFCache/workspace/WORKSPACE@*-json; do
        [ -f "$record" ] || continue
        ws=$(plutil -extract path raw "$record" -o - 2>/dev/null) || continue
        [ -n "$ws" ] || continue
        # A project's workspace is a directory inside the .xcodeproj; the suffix
        # strip is a no-op on a standalone .xcworkspace, which is already the
        # path the arena hashes from.
        printf '%s' "${ws%/project.xcworkspace}"
        return 0
    done
    return 1
}

# arena_holds_only_packages <dir> — whether <dir> holds nothing but a package
# resolution's Logs/ and SourcePackages/, so its name is the only thing that
# says whose it is (Tools/derived-data-path.sh computes that name).
arena_holds_only_packages() {
    local entry
    for entry in "$1"/* "$1"/.[!.]*; do
        [ -e "$entry" ] || continue
        case "${entry##*/}" in
            Logs | SourcePackages) ;;
            *) return 1 ;;
        esac
    done
}
