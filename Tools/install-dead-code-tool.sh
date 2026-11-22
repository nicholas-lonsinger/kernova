#!/usr/bin/env bash
# Installs one of the tools Tools/DeadCode builds, in release, into the
# machine's tool cache (Tools/lib/tool-cache.sh), and prints its path.
#
# Usage: Tools/install-dead-code-tool.sh <dead-code | dead-code-sources> [--path]
#   --path  print the tool's path, installing nothing
#
# Status text goes to stderr: stdout carries the path alone, so callers can
# read it with a command substitution.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/tool-cache.sh
. "$root/Tools/lib/tool-cache.sh"
# shellcheck source=lib/dead-code-tool.sh
. "$root/Tools/lib/dead-code-tool.sh"

usage() {
    echo 'usage: Tools/install-dead-code-tool.sh <dead-code | dead-code-sources> [--path]' >&2
    exit 2
}

case "${1:-}" in
    dead-code | dead-code-sources) product=$1 ;;
    *) usage ;;
esac
[ $# -le 2 ] || usage

inputs=("$product" release -- Tools/install-dead-code-tool.sh Tools/lib/dead-code-tool.sh Tools/lib/package-pins.sh
    Tools/DeadCode/Package.swift Tools/DeadCode/Package.resolved Tools/DeadCode/Sources)

build_tool() {
    dead_code_swift build -c release --product "$product" --quiet >&2
    local bin
    bin=$(dead_code_swift build -c release --show-bin-path)
    cp "$bin/$product" "$1/"
}

# With no command, a tool prints its usage and exits 1.
verify_tool() {
    local output
    if output=$("$1/$product" 2>&1); then
        return 1
    fi
    case "$output" in
        "$product: Usage:"*) ;;
        *)
            printf '%s\n' "$output" >&2
            return 1
            ;;
    esac
}

case "${2:-}" in
    '') dir=$(tool_install build_tool verify_tool "${inputs[@]}") ;;
    --path) dir=$(tool_dir "${inputs[@]}") ;;
    *) usage ;;
esac
printf '%s\n' "$dir/$product"
