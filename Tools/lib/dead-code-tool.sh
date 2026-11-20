# Every SwiftPM call on the dead-code tools' package, Tools/DeadCode, so each
# takes the same options, and the release dead-code-sources lint runs.
# Sourced, never run:
#
#     . "$ROOT/Tools/lib/dead-code-tool.sh"
#     dead_code_swift test --quiet
#     tool=$(installed_dead_code_sources)
#
# SwiftPM fetches prebuilt swift-syntax libraries, 115 MB of them, for any
# package that depends on swift-syntax, but they serve only macro targets and
# this package has none: `--disable-experimental-prebuilts`. A hook's children
# inherit GIT_DIR (githooks(5)), which outranks SwiftPM's own clones of the
# package's dependencies, so the calls run without git's local variables.

# shellcheck shell=bash

# shellcheck source=package-pins.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/package-pins.sh"

dead_code_package="$(cd "$(dirname "${BASH_SOURCE[0]}")/../DeadCode" && pwd)"

# dead_code_swift <subcommand> [<option>...] — `swift <subcommand>` on the package.
dead_code_swift() (
    # shellcheck disable=SC2046 # one variable name per word
    unset $(git rev-parse --local-env-vars)
    with_package_pins "$dead_code_package" swift "$1" --disable-experimental-prebuilts -- "${@:2}"
)

# installed_dead_code_sources — the path of the release dead-code-sources in
# the machine's tool cache, installed first if it is not there
# (Tools/install-dead-code-tool.sh). The cache is under the user's own home,
# whatever HOME names: a fixture suite runs under the scratch HOME isolate_git
# (git-isolation.sh) gives it.
installed_dead_code_sources() {
    HOME=$(perl -e 'print +(getpwuid $<)[7]') "${dead_code_package%/*}/install-dead-code-tool.sh" dead-code-sources
}
