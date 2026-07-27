#!/usr/bin/env bash
# Checks the two documentation rules that a machine can decide: the 80-word
# line cap from AGENTS.md's "Documentation and Comments", and that every
# relative Markdown link resolves.
#
# These two are here and the rest of the convention is not, because they are
# the only rules whose violation can be fixed without deleting anything. An
# over-long line is fixed by breaking it; a dead link by repointing it. Every
# other rule in that section — is this derivable, is this an external fact, is
# this the deepest layer — can only be satisfied by removing a sentence, and a
# checker that is sometimes wrong about those would delete facts on a false
# positive. Those stay with the reader.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

failures=0
fail() { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; failures=$((failures + 1)); }

# The cap applies to prose. A table row, a fenced code block, or a long URL is
# not a run-on sentence, and breaking one would corrupt it.
while IFS= read -r doc; do
    while IFS=$'\t' read -r lineno words; do
        fail "$doc:$lineno — $words words (cap 80)"
    done < <(awk '
        /^```/ { fenced = !fenced; next }
        fenced { next }
        /^[[:space:]]*\|/ { next }
        NF > 80 { printf "%d\t%d\n", NR, NF }
    ' "$doc")
done < <(git ls-files '*.md')

while IFS= read -r doc; do
    dir="$(dirname "$doc")"
    while IFS= read -r target; do
        # Strip an anchor, then resolve against the linking file's directory.
        path="${target%%#*}"
        [ -n "$path" ] || continue
        case "$path" in
            http://* | https://* | mailto:*) continue ;;
        esac
        [ -e "$dir/$path" ] && continue
        fail "$doc — dead link: $target"
    done < <(grep -oE '\]\([^)]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//')
done < <(git ls-files '*.md')

if [ "$failures" -gt 0 ]; then
    printf '\n%s documentation violation(s)\n' "$failures" >&2
    exit 1
fi

pass "docs: line cap and links"
