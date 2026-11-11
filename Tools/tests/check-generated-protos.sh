#!/usr/bin/env bash
# Fixture test for Tools/check-generated-protos.sh: building protoc with a git
# hook's environment, GIT_DIR naming the checkout being pushed, fetches and
# builds swift-protobuf without touching that checkout.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-generated-protos.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp" # also an empty HOME, so no protoc is cached

# A local stand-in for swift-protobuf, which the script's fetch URL is
# redirected to.
upstream="$tmp/swift-protobuf"
git init -q -b main "$upstream" && git -C "$upstream" commit -q --allow-empty -m upstream || exit 1
revision=$(git -C "$upstream" rev-parse HEAD) || exit 1
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global url."file://$upstream".insteadOf https://github.com/apple/swift-protobuf.git
git config --global uploadpack.allowAnySHA1InWant true

# The checkout being pushed: one schema, and a Package.resolved pinning the
# stand-in's commit.
caller="$tmp/caller"
resolved="$caller/Kernova.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
git init -q -b main "$caller" || exit 1
mkdir -p "${resolved%/*}"
printf '{\n  "pins" : [\n    {\n      "identity" : "swift-protobuf",\n      "state" : {\n        "revision" : "%s"\n      }\n    }\n  ]\n}\n' \
    "$revision" >"$resolved"
printf 'syntax = "proto3";\n' >"$caller/schema.proto"
git -C "$caller" add -A && git -C "$caller" commit -q -m caller || exit 1
caller_head=$(git -C "$caller" rev-parse HEAD)

# The build step only records what repository it would see.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nprintf "GIT_DIR=%%s\\n" "${GIT_DIR-<unset>}" >>"%s"\nexit 1\n' "$tmp/xcrun.log" >"$tmp/bin/xcrun"
chmod +x "$tmp/bin/xcrun"

output=$(cd "$caller" && GIT_DIR="$caller/.git" PATH="$tmp/bin:$PATH" bash "$check_script" 2>&1)

if [ "$(git -C "$caller" symbolic-ref -q HEAD)" != refs/heads/main ] ||
    [ "$(git -C "$caller" rev-parse HEAD)" != "$caller_head" ]; then
    fail "hook-environment: moved the caller's HEAD to '$(git -C "$caller" rev-parse HEAD)' ($(git -C "$caller" symbolic-ref -q HEAD || echo detached)), wanted refs/heads/main at $caller_head"
fi
if [ ! -s "$tmp/xcrun.log" ]; then
    fail "hook-environment: never reached the build; output: $output"
elif grep -qv '^GIT_DIR=<unset>$' "$tmp/xcrun.log"; then
    fail "hook-environment: built with the caller's repository: $(sort -u "$tmp/xcrun.log" | tr '\n' ' ')"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'check-generated-protos fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-generated-protos fixtures: all passed\n'
