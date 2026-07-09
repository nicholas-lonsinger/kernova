#!/bin/sh
#
# set-build-number.sh — compute CFBundleVersion and emit the preprocessor
# header that INFOPLIST_PREFIX_HEADER feeds into a target's Info.plist.
#
# Usage: set-build-number.sh <app|agent>
#
# The number is *squash-merge aware*. A checkout reports the commit count it will
# have once its PR squash-merges into main, and holds that value steady across a
# branch's own commits instead of climbing by one per commit:
#
#     base   = git merge-base HEAD origin/main   # after a rebase, == origin/main tip
#     number = <commits reachable from base> + <1 if this checkout has pending work>
#
# "Pending work" = a commit beyond base OR an uncommitted change (a dirty tree is
# the in-progress next commit; untracked non-ignored files count, gitignored build
# output does not). So the ONLY +0 case is a clean checkout of a commit already on
# main (reading its own position); anything with work of its own is +1, and commits
# + dirt still collapse to a single squash commit, so it never exceeds +1. On main
# with a clean tree the number equals the old `git rev-list --count HEAD`, so what
# ships (archived from main) is unchanged. When main advances, git forces a rebase
# to merge; that rebase moves `base` forward and re-derives the number — the rebase
# is the natural trigger, not a per-commit creep.
#
# app mode counts every commit / any change. agent mode counts only commits and
# changes touching the guest-agent sources, so an app-only PR leaves the agent's
# number untouched — mirroring how a single squash commit moves each by at most one.
#
# Environment (exported by Xcode): SRCROOT, DERIVED_FILE_DIR.

set -eu

MODE="${1:-}"
case "$MODE" in
    app)   DEFINE="KERNOVA_BUILD_NUMBER"; HEADER="KernovaBuildNumber.h" ;;
    agent) DEFINE="AGENT_BUILD_NUMBER";   HEADER="AgentBuildNumber.h" ;;
    *) echo "error: usage: $0 <app|agent>" >&2; exit 1 ;;
esac

g() { git -C "${SRCROOT}" "$@"; }

# rev-list --count for the mode. agent scopes to the guest-agent sources — both
# the pre- and post-rename directories, so the count stays monotonic across the
# rename, matching the scope the agent build number has always used.
count() { # $1 = rev
    if [ "$MODE" = agent ]; then
        g rev-list --count "$1" -- KernovaGuestAgent/ KernovaMacOSAgent/
    else
        g rev-list --count "$1"
    fi
}

# Does this checkout carry work not yet on main that becomes the squash commit,
# moving this number by one? Work = a commit beyond base OR an uncommitted change.
# `--no-optional-locks` keeps the parallel per-target phases from racing on the
# index lock; `status --porcelain` also catches untracked (non-ignored) files.
# app: any commit/change. agent: only ones touching the guest-agent sources.
has_pending_work() { # $1 = base
    if [ "$MODE" = agent ]; then
        ! g diff --quiet "$1" HEAD -- KernovaGuestAgent/ KernovaMacOSAgent/ \
            || [ -n "$(g --no-optional-locks status --porcelain -- KernovaGuestAgent/ KernovaMacOSAgent/)" ]
    else
        [ -n "$(g rev-list "$1"..HEAD)" ] \
            || [ -n "$(g --no-optional-locks status --porcelain)" ]
    fi
}

# Resolve the mainline ref to measure against; prefer the remote-tracking main.
main_ref=""
for ref in origin/main main; do
    if g rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
        main_ref="$ref"
        break
    fi
done

number=""
if [ -n "$main_ref" ] && base="$(g merge-base HEAD "$main_ref" 2>/dev/null)" && [ -n "$base" ]; then
    number="$(count "$base")"
    if has_pending_work "$base"; then
        number=$((number + 1))
    fi
fi

# Fallback: no mainline ref or no merge-base (e.g. a CI shallow clone with
# fetch-depth: 1, or a fresh clone before the first fetch). Such builds are
# never archived, so the legacy HEAD count is a fine stand-in.
if [ -z "$number" ]; then
    number="$(count HEAD)"
fi

if [ -z "$number" ]; then
    echo "error: could not determine ${MODE} build number from git history" >&2
    exit 1
fi

mkdir -p "${DERIVED_FILE_DIR}"
echo "#define ${DEFINE} ${number}" > "${DERIVED_FILE_DIR}/${HEADER}"
