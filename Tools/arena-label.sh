#!/usr/bin/env bash
# Name the checkout that a build path belongs to.
#
# In Xcode's default derived-data mode every arena is named by a hash of the
# .xcodeproj path — `Kernova-cylpmrailymlsackwzjwvurxnpbj` — which says nothing
# about whose build it holds. With several worktrees open at once (the normal
# state here), "which checkout is that one?" is the question every arena line
# raises, and answering it by hand means dumping info.plist. This resolves the
# hash back to a human label so the tooling can print it inline.
#
# Usage: Tools/arena-label.sh [--status] <path>
#   <path> may be a build arena, anything inside one (a Kernova.app), or a
#   checkout directory itself.
#
# Prints exactly one of these and exits 0:
#   worktree: <name>              a live .claude/worktrees/<name> worktree
#   worktree: <name>, removed     an arena that outlived its worktree
#   main checkout                 the primary checkout
#   other checkout: <dir>         a different clone or project entirely
#
# With --status, prints the machine-readable kind instead — one of
# `worktree-live`, `worktree-removed`, `main`, `other`. Callers branch on this rather than
# on the human label: matching the label is a format dependency, and the
# `, removed` suffix is presentation.
#
# Exits 1 printing nothing when the path can't be attributed (no info.plist to
# read, a path outside every known checkout, not a git repo). Callers append the
# label only when there is one, so an unattributable path just renders bare.
#
# Consumed by Tools/ghosts.sh (arena and on-disk-copy lines, plus the orphan
# scan via --status) and Tools/doctor.sh (the build-arena report).

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

# The worktrees all live under the *primary* checkout's .claude/worktrees/,
# which REPO_ROOT is not when this runs from inside a worktree — the first
# `git worktree list` entry is the primary checkout.
main_root=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main_root" ] || exit 1

worktrees_root="$main_root/.claude/worktrees"

# Display-only: abbreviate $HOME to ~, matching Tools/ghosts.sh's pretty_path.
pretty() { printf '%s' "${1/#$HOME/~}"; }

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
            # A worktree whose directory is gone still names itself here — that
            # is the whole point for orphaned arenas, which outlive the
            # worktree that created them.
            if [ -d "$worktrees_root/$name" ]; then
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

# A path already inside a checkout needs no plist lookup — this covers a
# Relative-mode in-checkout DerivedData/ and a checkout passed directly.
label_for_checkout "$target" && exit 0

# Otherwise walk up to the arena root, where Xcode records the project it built
# from. That record is readable after the source worktree is deleted, which is
# what lets an orphaned arena still name the worktree it came from.
#
# A plist that exists but carries no WorkspacePath does NOT end the walk. The
# probe is case-insensitive on a stock APFS volume, so `info.plist` also matches
# the `Info.plist` of every bundle on the way up; treating that hit as terminal
# drops the label from any path that passes through a bundle's Contents/ before
# reaching the arena.
dir=$target
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/info.plist" ]; then
        ws=$(plutil -extract WorkspacePath raw "$dir/info.plist" -o - 2>/dev/null) || ws=''
        if [ -n "$ws" ]; then
            label_for_checkout "$ws" && exit 0
            # A different project's arena: name its directory rather than
            # guessing at a friendlier label.
            if [ "$STATUS_ONLY" = 1 ]; then
                printf 'other'
            else
                printf 'other checkout: %s' "$(pretty "${ws%/*}")"
            fi
            exit 0
        fi
    fi
    dir=$(dirname "$dir")
done

exit 1
