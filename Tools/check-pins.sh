#!/usr/bin/env bash
# Every pin Tools/outdated-pins.sh compares with upstream reads, so a new or
# reworded one fails here rather than in a scheduled run: .swift-version holds
# a release, each Tools/install-*.sh declares the tag it pins or that it pins
# none, and each Package.resolved the report covers pins releases
# (Tools/lib/pins.sh). Reports every failure before failing.

set -uo pipefail

# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/pins.sh
. Tools/lib/pins.sh

if ! pins_declared; then
    echo 'check-pins: a pin above does not read — declare it as Tools/lib/pins.sh says' >&2
    exit 1
fi
pass "pins: .swift-version, $(pins_installers | wc -l | tr -d ' ') installers and the Package.resolved pins Dependabot leaves out all read"
