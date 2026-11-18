#!/usr/bin/env bash
# The dead-code scan tool's own suite (Tools/DeadCode): the rule combining the
# platforms' reports, the index filter, the build graph that names the
# targets only tests reach, and the reading of what only a Debug build
# compiles, each against inputs the tests write.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/dead-code-tool.sh
. "$ROOT/Tools/lib/dead-code-tool.sh"
dead_code_swift test --quiet
