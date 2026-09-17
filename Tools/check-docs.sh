#!/usr/bin/env bash
# Checks the two documentation rules that a machine can decide: a prose line
# caps at 80 words — this check is where that cap is stated — and every
# relative Markdown link resolves, the file it names and the heading its
# `#fragment` names.
#
# These two are here and the rest of the documentation convention is not,
# because they are the only rules whose violation can be fixed without deleting
# anything. An over-long line is fixed by breaking it; a dead link by
# repointing it. Every other rule — is this derivable, is this an external
# fact, is this the deepest layer — can only be satisfied by removing a
# sentence, and a checker that is sometimes wrong about those would delete
# facts on a false positive. Those stay with the reader.
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

# The anchor ids GitHub gives a Markdown file's headings, in document order:
# the heading text lowercased, everything but letters, digits, hyphens,
# underscores and spaces dropped, spaces turned into hyphens, and a repeat of
# an earlier id suffixed -1, -2. A fenced block holds no headings — the commit
# template in AGENTS.md's "Commit Messages" is `## Summary` inside one.
heading_slugs() {
    awk '
        {
            marker = ""
            if ($0 ~ /^[[:space:]]*```/)  marker = "`"
            if ($0 ~ /^[[:space:]]*~~~/)  marker = "~"
            if (marker != "") {
                if (fence == "") fence = marker
                else if (fence == marker) fence = ""
                next
            }
            if (fence != "") next

            if ($0 !~ /^#+[[:space:]]/) next
            hashes = $0
            sub(/[[:space:]].*$/, "", hashes)
            if (length(hashes) > 6) next

            text = $0
            sub(/^#+[[:space:]]+/, "", text)
            sub(/[[:space:]]+#+[[:space:]]*$/, "", text)

            slug = tolower(text)
            gsub(/[^a-z0-9 _-]/, "", slug)
            gsub(/ /, "-", slug)
            if (slug == "") next

            repeats = seen[slug]++
            if (repeats) slug = slug "-" repeats
            print slug
        }
    ' "$1"
}

while IFS= read -r doc; do
    dir="$(dirname "$doc")"
    while IFS= read -r target; do
        case "$target" in
            http://* | https://* | mailto:*) continue ;;
        esac
        # Split the anchor off, then resolve the path against the linking
        # file's directory. An empty path anchors within the linking file.
        path="${target%%#*}"
        case "$target" in
            *'#'*) fragment="${target#*#}" ;;
            *) fragment="" ;;
        esac
        if [ -n "$path" ]; then
            target_doc="$dir/$path"
            if [ ! -e "$target_doc" ]; then
                fail "$doc — dead link: $target"
                continue
            fi
        else
            target_doc="$doc"
        fi
        [ -n "$fragment" ] || continue
        case "$target_doc" in *.md) ;; *) continue ;; esac
        heading_slugs "$target_doc" | grep -qxF -- "$fragment" && continue
        fail "$doc — dead anchor: $target"
    done < <(grep -oE '\]\([^)]+\)' "$doc" | sed -E 's/^\]\(//; s/\)$//')
done < <(git ls-files '*.md')

if [ "$failures" -gt 0 ]; then
    printf '\n%s documentation violation(s)\n' "$failures" >&2
    exit 1
fi

pass "docs: line cap and links"
