#!/usr/bin/env bash
# The dead-code scan tool's own suite (Tools/DeadCode): the rule combining the
# platforms' reports, the index filter, and the build graph that names the
# targets only tests reach, each against inputs the tests write.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
swift test --quiet --package-path "$ROOT/Tools/DeadCode"
