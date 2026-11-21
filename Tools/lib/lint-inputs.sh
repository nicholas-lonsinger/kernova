# What Tools/lint.sh lints, read from git's index and the checks' and suites'
# own headers. Sourced, never run; run from the repository root.

# shellcheck shell=bash

# tracked <glob>... — the tracked paths matching any glob, where `*` stops at
# a `/` and `**/` spans directories, the root included.
tracked() {
    local pathspecs=() glob
    for glob in "$@"; do pathspecs+=(":(glob)$glob"); done
    git ls-files -- "${pathspecs[@]}"
}

# lint_shell_sources — the shell scripts, the guest agent's .command
# installers, and the git hooks.
lint_shell_sources() { tracked '**/*.sh' '**/*.command' '.githooks/*'; }

lint_checks() { tracked 'Tools/check-*.sh'; }

# lint_fixture_suites — the Tools/tests scripts and each skill's tests/run.sh.
lint_fixture_suites() { tracked 'Tools/tests/*.sh' '.agents/skills/*/tests/run.sh'; }

# lint_fixture_reads <suite> — the paths, relative to the repository root,
# the suite's header declares it reads beyond itself, one per line, from
# header lines
#
#     # fixture reads: <path>...
#
# where a directory stands for every file under it. A header line spelling
# `fixture read` any other way fails, naming it.
lint_fixture_reads() {
    awk 'NR == 1 && /^#!/ { next } /^#/ { print; next } { exit }' "$1" | awk -v suite="$1" '
        /^# fixture reads: [^ ]/ {
            n = split(substr($0, length("# fixture reads: ") + 1), paths, " ")
            for (i = 1; i <= n; i++) print paths[i]
            next
        }
        tolower($0) ~ /^# *fixture *read/ {
            printf "lint: %s: '\''%s'\'' is not '\''# fixture reads: <path>...'\''\n", suite, $0 > "/dev/stderr"
            bad = 1
        }
        END { exit bad }'
}

# lint_order <check> — `first`, `last` or `not-run`, from the check's header:
# the comment block it opens with. A header line
#
#     # make lint: runs last — <why>
#     # make lint: not run — <who runs it>
#
# makes it `last` or `not-run`; no such line makes it `first`. Any other
# `# make lint:` line in the header fails, naming it.
lint_order() {
    local declared
    declared=$(awk 'NR == 1 && /^#!/ { next } /^#/ { print; next } { exit }' "$1" | grep -m 1 '^# make lint:')
    case "$declared" in
        '') echo first ;;
        '# make lint: runs last — '?*) echo last ;;
        '# make lint: not run — '?*) echo not-run ;;
        *)
            echo "lint: $1: '$declared' is not '# make lint: runs last — <why>' or '# make lint: not run — <who runs it>'" >&2
            return 1
            ;;
    esac
}
