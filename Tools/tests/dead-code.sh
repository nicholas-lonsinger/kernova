#!/usr/bin/env bash
# The dead-code scan tools' own suite (Tools/DeadCode): the rule combining the
# platforms' reports, the index filter, the build graph that names the
# targets only tests reach, and the reading of what only a Debug build
# compiles, each against inputs the tests write.
#
# fixture reads: Tools/lib/dead-code-tool.sh Tools/lib/package-pins.sh Tools/DeadCode

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/dead-code-tool.sh
. "$ROOT/Tools/lib/dead-code-tool.sh"
dead_code_swift test --quiet
