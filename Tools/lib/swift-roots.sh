# The roots swift-format covers, for `make format` and Tools/lint.sh. Sourced,
# never run.

# shellcheck shell=bash

# swift_roots — the top-level entries holding a tracked .swift file, so a new
# target directory is covered once it is tracked. swift-format recurses into a
# directory, untracked files included, and takes a top-level .swift file as a
# path.
swift_roots() { git ls-files '*.swift' | cut -d/ -f1 | sort -u; }
