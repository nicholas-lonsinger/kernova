#!/usr/bin/env bash
# Writes this checkout's buildServer.json — the Build Server Protocol config
# sourcekit-lsp reads to learn each file's compiler flags, so editors and
# Claude Code's Swift language server see the real Xcode build context instead
# of a bare file. Run via `make install-lsp`; .githooks/post-checkout calls it
# for a new worktree.
#
# Usage: Tools/lsp-config.sh [<project> <scheme>] — defaulting to the Makefile's
# PROJECT and SCHEME, which the make target passes explicitly.
#
# The config pins an absolute build root, so every checkout writes its own and
# the file must never be copied between worktrees (which is why it is not in
# .worktreeinclude). xcode-build-server reads Xcode's build log at language-
# server time: writing the config needs no build, but the language server has
# no flags to serve until this checkout has been built once.
#
# Exits 0 when xcode-build-server is absent, after naming the remedy — the hook
# calls this, and an optional tool must never fail a checkout.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

project="${1:-Kernova.xcodeproj}"
scheme="${2:-Kernova}"

if ! command -v xcode-build-server >/dev/null 2>&1; then
    warn "xcode-build-server absent — run 'make install-lsp' for Swift language-server context"
    exit 0
fi

xcode-build-server config -project "$project" -scheme "$scheme" || exit 1
pass "buildServer.json written for the $scheme scheme"
