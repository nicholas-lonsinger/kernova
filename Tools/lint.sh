#!/usr/bin/env bash
# Lints the checkout: what `Tools/attest.sh record lint` runs, for `make lint`.
# Stops at the first failing step.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=lib/output.sh
. Tools/lib/output.sh
# shellcheck source=lib/swift-roots.sh
. Tools/lib/swift-roots.sh

die() { echo "lint: $1" >&2; exit 1; }

shell_sources=()
while IFS= read -r f; do shell_sources+=("$f"); done < <(git ls-files '*.sh' '*.command')
[ "${#shell_sources[@]}" -gt 0 ] || die 'git tracks no shell scripts — not a git checkout?'
command -v shellcheck >/dev/null 2>&1 || die 'shellcheck is not installed: brew install shellcheck'
shellcheck "${shell_sources[@]}" || exit 1
pass "shellcheck: ${#shell_sources[@]} scripts"

for check in Tools/check-agent-deployment-floor.sh Tools/check-package-origins.sh Tools/check-release-entitlements.sh \
    Tools/check-wire-decodes.sh; do
    bash "$check" || exit 1
done

swift=()
while IFS= read -r root; do swift+=("$root"); done < <(swift_roots)
[ "${#swift[@]}" -gt 0 ] || die 'git tracks no Swift sources — not a git checkout?'
xcrun swift-format lint --strict --parallel --recursive "${swift[@]}" || exit 1
pass "swift-format: ${#swift[@]} roots"

bash Tools/tests/prune-worktrees.sh || exit 1
