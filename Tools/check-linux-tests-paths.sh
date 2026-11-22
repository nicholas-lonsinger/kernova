#!/usr/bin/env bash
# The Linux tests' inputs, as Tools/lib/linux-tests.sh names them, are what
# CI's Portable Targets workflow triggers on: each `paths` filter in
# .github/workflows/portable.yml lists exactly `.github/workflows/**` and each
# named path — a file as itself, a directory as `<dir>/**` — or is an alias of
# such a list. Each named path must be tracked, so a path that moved fails
# here instead of leaving a stale name in both.
#
# Reports every violation before failing, so one run fixes them all.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"
# shellcheck source=lib/linux-tests.sh
. "$lib_dir/lib/linux-tests.sh"

workflow=.github/workflows/portable.yml
[ -f "$workflow" ] || { echo "check-linux-tests-paths: $workflow is missing" >&2; exit 1; }

status=0
violation() { echo "check-linux-tests-paths: $1" >&2; status=1; }

expected='.github/workflows/**'
while IFS= read -r path; do
    tracked=$(git ls-files -- "$path")
    if [ -z "$tracked" ]; then
        violation "Tools/lib/linux-tests.sh names $path, which git does not track"
    elif [ "$tracked" = "$path" ]; then
        expected+=$'\n'"$path"
    else
        expected+=$'\n'"$path/**"
    fi
done < <(linux_tests_paths)
expected=$(printf '%s\n' "$expected" | LC_ALL=C sort)

# Each `paths:` key on its own line, as `<line> list <anchor or -> <entries>`
# for a block list and `<line> alias <name>` for an alias.
filters=$(awk '
    function flush() { if (open) { print start " list " anchor " " entries; open = 0 } }
    /^[[:space:]]*paths:/ {
        flush()
        value = $0
        sub(/^[[:space:]]*paths:[[:space:]]*/, "", value)
        if (value ~ /^\*/) { print NR " alias " substr(value, 2); next }
        open = 1; start = NR; entries = ""
        anchor = (value ~ /^&/) ? substr(value, 2) : "-"
        next
    }
    open && /^[[:space:]]*- / {
        entry = $0
        sub(/^[[:space:]]*- [[:space:]]*/, "", entry)
        gsub(/^["\047]|["\047][[:space:]]*$/, "", entry)
        entries = entries (entries == "" ? "" : ",") entry
        next
    }
    { flush() }
    END { flush() }
' "$workflow")
[ -n "$filters" ] || violation "$workflow has no paths filter"

anchors=' '
while read -r line kind name entries; do
    [ "$kind" = list ] || continue
    [ "$name" = - ] || anchors+="$name "
    got=$(printf '%s\n' "${entries//,/$'\n'}" | LC_ALL=C sort)
    if [ "$got" != "$expected" ]; then
        violation "$workflow:$line lists $(printf '%s' "$got" | paste -sd ' ' -); the Linux tests' inputs are $(printf '%s' "$expected" | paste -sd ' ' -)"
    fi
done <<<"$filters"
while read -r line kind name _; do
    [ "$kind" = alias ] || continue
    case "$anchors" in *" $name "*) ;; *) violation "$workflow:$line aliases $name, which anchors no paths list" ;; esac
done <<<"$filters"

[ "$status" -eq 0 ] && pass "Linux tests' inputs: $workflow triggers on each of them"
exit "$status"
