#!/bin/sh
#
# set-build-number.sh — compute CFBundleVersion and emit the preprocessor
# header that INFOPLIST_PREFIX_HEADER feeds into a target's Info.plist.
#
# Usage: set-build-number.sh app
#
# The number is squash-merge aware. Every target that labels itself takes the
# same one, so a guest agent claims the label the host bundles it under.
#
# Environment (exported by Xcode): SRCROOT, DERIVED_FILE_DIR.

set -eu

MODE="${1:-}"
case "$MODE" in
    app) DEFINE="KERNOVA_BUILD_NUMBER"; HEADER="KernovaBuildNumber.h" ;;
    *) echo "error: usage: $0 app" >&2; exit 1 ;;
esac

g() { git -C "${SRCROOT}" "$@"; }

count() { # $1 = rev
    g rev-list --count "$1"
}

# Does this checkout carry work not yet on main that becomes the squash commit,
# moving this number by one? Work = a commit beyond base OR an uncommitted change.
# `--no-optional-locks` keeps the parallel per-target phases from racing on the
# index lock; `status --porcelain` also catches untracked (non-ignored) files.
has_pending_work() { # $1 = base
    [ -n "$(g rev-list "$1"..HEAD)" ] \
        || [ -n "$(g --no-optional-locks status --porcelain)" ]
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
    echo "error: could not determine the build number from git history" >&2
    exit 1
fi

mkdir -p "${DERIVED_FILE_DIR}"
echo "#define ${DEFINE} ${number}" > "${DERIVED_FILE_DIR}/${HEADER}"
