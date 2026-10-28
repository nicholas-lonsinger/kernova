# The Static Linux SDK release built for the toolchain .swift-version pins,
# and its checksum from https://www.swift.org/api/v1/install/releases.json.
# Moving .swift-version moves these with it; a stale pair fails the checksum
# rather than installing. Sourced, never run, by every script that installs
# or builds with the SDK, and by the Linux CI job.

# shellcheck shell=bash
# shellcheck disable=SC2034 # read by the scripts that source this
STATIC_SDK_VERSION=0.1.0
# shellcheck disable=SC2034
STATIC_SDK_CHECKSUM=cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
