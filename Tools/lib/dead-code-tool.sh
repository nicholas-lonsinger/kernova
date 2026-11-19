# Every SwiftPM call on the dead-code tool's package, Tools/DeadCode, so each
# takes the same options. Sourced, never run:
#
#     . "$ROOT/Tools/lib/dead-code-tool.sh"
#     dead_code_swift build -c release --quiet
#     dead_code_swift test --quiet
#
# SwiftPM fetches prebuilt swift-syntax libraries, 115 MB of them, for any
# package that depends on swift-syntax, but they serve only macro targets and
# this package has none: `--disable-experimental-prebuilts`. A hook's children
# inherit GIT_DIR (githooks(5)), which outranks SwiftPM's own clones of the
# package's dependencies, so the calls run without git's local variables.

# shellcheck shell=bash

# shellcheck source=pinned-swift.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pinned-swift.sh"

dead_code_package="$(cd "$(dirname "${BASH_SOURCE[0]}")/../DeadCode" && pwd)"

# dead_code_swift <subcommand> [<option>...] — `swift <subcommand>` on the package.
dead_code_swift() (
    # shellcheck disable=SC2046 # one variable name per word
    unset $(git rev-parse --local-env-vars)
    pinned_swift "$dead_code_package" swift "$1" --disable-experimental-prebuilts -- "${@:2}"
)
