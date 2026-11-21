# The paths a fixture suite declares it reads, from its header. Sourced, never
# run.

# shellcheck shell=bash

# fixture_reads <suite> — the paths, relative to the repository root, the
# suite's header declares it reads beyond itself, one per line, from header
# lines
#
#     # fixture reads: <path>...
#
# where a directory stands for every file under it. A header line spelling
# `fixture read` any other way fails, naming it.
fixture_reads() {
    awk 'NR == 1 && /^#!/ { next } /^#/ { print; next } { exit }' "$1" | awk -v suite="$1" '
        /^# fixture reads: [^ ]/ {
            n = split(substr($0, length("# fixture reads: ") + 1), paths, " ")
            for (i = 1; i <= n; i++) print paths[i]
            next
        }
        tolower($0) ~ /^# *fixture *read/ {
            printf "fixture-reads: %s: '\''%s'\'' is not '\''# fixture reads: <path>...'\''\n", suite, $0 > "/dev/stderr"
            bad = 1
        }
        END { exit bad }'
}
