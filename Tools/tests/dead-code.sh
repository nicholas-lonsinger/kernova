#!/usr/bin/env bash
# The dead-code scan tool's own suite (Tools/DeadCode): the rule combining the
# platforms' reports, the index filter, the build graph that names the
# targets only tests reach, and the reading of what only a Debug build
# compiles, each against inputs the tests write.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# A hook's children inherit GIT_DIR (githooks(5)), as this suite does under
# git-isolation.sh, and it outranks SwiftPM's own clones of the package's
# dependencies.
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
swift test --quiet --package-path "$ROOT/Tools/DeadCode"
