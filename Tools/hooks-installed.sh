#!/usr/bin/env bash
# Reports (via exit status) whether this repo's checked-in git hooks are
# active: core.hooksPath is set and the directory it resolves to contains the
# executable pre-push and post-checkout hooks. Verifies reality rather than
# string-comparing the config value against ".githooks" — an absolute path
# (or any other spelling) that resolves to a working hooks directory counts
# as installed; the literal comparison used to produce false "not installed"
# nudges for exactly that setup.
#
# A relative core.hooksPath resolves against the directory git runs hooks
# from — the working-tree root — so resolve the same way here. On success,
# prints the resolved path for callers that display it (Tools/doctor.sh);
# `make check-hooks` redirects stdout and uses only the exit status.

set -uo pipefail

hp=$(git config --get core.hooksPath 2>/dev/null)
[ -n "$hp" ] || exit 1

case "$hp" in
    /*) ;;
    *) hp="$(git rev-parse --show-toplevel)/$hp" ;;
esac

{ [ -x "$hp/pre-push" ] && [ -x "$hp/post-checkout" ]; } || exit 1
printf '%s\n' "$hp"
