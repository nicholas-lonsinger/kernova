#!/usr/bin/env bash
# Name the checkout that a build path belongs to.
#
# In Xcode's default derived-data mode every arena is named by a hash of the
# .xcodeproj path — `Kernova-cylpmrailymlsackwzjwvurxnpbj` — which says nothing
# about whose build it holds. With several worktrees open at once (the normal
# state here), "which checkout is that one?" is the question every arena line
# raises, and answering it by hand means digging through the arena's own
# records. This resolves the hash back to a human label so the tooling can print
# it inline.
#
# Usage: Tools/arena-label.sh [--status] <path>
#   <path> may be a build arena, anything inside one (a Kernova.app), or a
#   checkout directory itself.
#
# Prints exactly one of these and exits 0:
#   worktree: <name>                a live .claude/worktrees/<name> worktree
#   worktree: <name>, removed       an arena that outlived its worktree
#   main checkout                   the primary checkout
#   other checkout: <dir>           any other checkout: a different clone or
#                                   project, or a worktree registered outside
#                                   .claude/worktrees/
#   other checkout: <dir>, removed  …one that is no longer on disk
#   packages only, no checkout here an arena that only ever resolved packages,
#                                   named for none of this clone's checkouts
#
# Both `, removed` forms say the same thing: the arena outlived the checkout it
# belongs to.
#
# With --status, prints the machine-readable kind instead — one of
# `worktree-live`, `worktree-removed`, `main`, `other`, `other-removed`,
# `unclaimed`. Callers
# branch on this rather than on the human label: matching the label is a format
# dependency, and the `, removed` suffix is presentation.
#
# Exits 1 printing nothing when the path can't be attributed (an arena holding
# neither record of the project it came from, a path outside every known
# checkout, not a git repo). Callers append the label only when there is one, so
# an unattributable path just renders bare.

set -uo pipefail

STATUS_ONLY=0
if [ "${1:-}" = "--status" ]; then
    STATUS_ONLY=1
    shift
fi

[ -n "${1:-}" ] || exit 1

target=$1
case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/output.sh
. "$REPO_ROOT/Tools/lib/output.sh"
# shellcheck source=lib/worktrees.sh
. "$REPO_ROOT/Tools/lib/worktrees.sh"
# shellcheck source=lib/arena-records.sh
. "$REPO_ROOT/Tools/lib/arena-records.sh"
read_worktree_layout "$REPO_ROOT" || exit 1

# label_for_checkout <path> — classify a path that names a checkout or sits
# inside one, then emit either the human label or the --status token from that
# one decision, so the two forms can never disagree. The worktrees case must be
# tested first: a worktree path is also under $main_root, so the order is what
# keeps a worktree from reporting as the main checkout.
label_for_checkout() {
    local p=$1 name
    case "$p" in
        "$worktrees_root"/*)
            name=${p#"$worktrees_root/"}
            name=${name%%/*}
            # A worktree git no longer registers still names itself here — that
            # is the whole point for orphaned arenas, which outlive the
            # worktree that created them.
            if worktree_live "$worktrees_root/$name"; then
                [ "$STATUS_ONLY" = 1 ] && { printf 'worktree-live'; return 0; }
                printf 'worktree: %s' "$name"
            else
                [ "$STATUS_ONLY" = 1 ] && { printf 'worktree-removed'; return 0; }
                # Comma, not a nested "(removed)": callers wrap this label in
                # parentheses, and a paren inside a paren reads badly.
                printf 'worktree: %s, removed' "$name"
            fi
            return 0
            ;;
        "$main_root" | "$main_root"/*)
            if [ "$STATUS_ONLY" = 1 ]; then printf 'main'; else printf 'main checkout'; fi
            return 0
            ;;
    esac
    return 1
}

# A path already inside a checkout needs no arena lookup — this covers a
# Relative-mode in-checkout DerivedData/ and a checkout passed directly.
label_for_checkout "$target" && exit 0

# Otherwise walk up to the arena root, where Xcode records the project the arena
# belongs to. That record is readable after the source worktree is deleted, which
# is what lets an orphaned arena still name the worktree it came from.
#
# A directory carrying neither record does NOT end the walk. The info.plist
# probe is case-insensitive on a stock APFS volume, so it also matches the
# `Info.plist` of every bundle on the way up; treating that hit as terminal
# drops the label from any path that passes through a bundle's Contents/ before
# reaching the arena.
dir=$target
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if ws=$(arena_recorded_project "$dir"); then
        label_for_checkout "$ws" && exit 0
        # A checkout outside this repo's layout — another clone, or a copy
        # staged somewhere temporary: name its directory rather than
        # guessing at a friendlier label.
        #
        # Removed-ness is tested on the recorded .xcodeproj rather than its
        # directory, because that path is what the arena's identity hashes
        # from: once it is gone nothing can ever build into this arena
        # again, whether the whole checkout went with it or only the
        # project file.
        removed=''
        [ -e "$ws" ] || removed=1
        if [ "$STATUS_ONLY" = 1 ]; then
            printf 'other%s' "${removed:+-removed}"
        else
            printf 'other checkout: %s%s' "$(pretty_path "${ws%/*}")" "${removed:+, removed}"
        fi
        exit 0
    fi
    dir=$(dirname "$dir")
done

# An arena that has only resolved packages carries neither record. Its name is
# still a pure function of its project's path (Tools/derived-data-path.sh), so it
# is matched forwards against every checkout this clone registers.
[[ ${target##*/} =~ ^Kernova-[a-z]{28}$ ]] && [ -d "$target" ] || exit 1
while IFS= read -r checkout; do
    [ -n "$checkout" ] || continue
    [ "$("$REPO_ROOT/Tools/derived-data-path.sh" "$checkout/Kernova.xcodeproj" 2>/dev/null)" = "$target" ] || continue
    label_for_checkout "$checkout" && exit 0
    # A registered worktree outside .claude/worktrees/.
    if [ "$STATUS_ONLY" = 1 ]; then printf 'other'; else printf 'other checkout: %s' "$(pretty_path "$checkout")"; fi
    exit 0
done <<<"$worktree_paths"

# Matching none, it can only belong to a checkout outside this clone. Holding
# nothing but that resolution, it costs such a checkout one re-resolve at most.
arena_holds_only_packages "$target" || exit 1
if [ "$STATUS_ONLY" = 1 ]; then printf 'unclaimed'; else printf 'packages only, no checkout here'; fi
exit 0
