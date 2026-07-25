# Shared terminal output helpers for the Tools/ scripts. Sourced, never run:
#
#     lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "$lib_dir/lib/output.sh"
#
# This file exists because ghosts.sh, doctor.sh and bootstrap-team.sh each
# carried a byte-identical copy of the colour block and the marker helpers, and
# copies drift: the moment one script's palette was corrected the other two were
# silently left behind. Colours and the presentation rules below now live here
# once. Semantics stay with each script — a marker that also increments a
# counter (doctor's `fail`, ghosts' `ghost`/`fixed`) is defined by its owner,
# because the counter is what the script's summary reports on.
#
# The presentation rules, which are the part that has to stay consistent:
#
#   pass/warn/fail markers  one line, one glyph, at two spaces.
#   value()                 DATA — a path, version, id, or resolved setting.
#                           Prints in the terminal's DEFAULT foreground.
#   detail()                ASIDE — an explanation, a remediation command, a
#                           pointer to another target. Dim, and skippable.
#
# The value/detail split is the rule worth keeping: dimming an aside is the
# point of it, but dimming a version number or a resolved path hides the answer
# the user ran the command to get. Default foreground for data is also the only
# choice that stays legible under both light and dark terminal themes, which no
# explicit colour can promise.
#
# c_dim is SGR 2 (faint), NOT 90m ("bright black"). 90m is a fixed dark grey:
# against a dark background it lands almost on top of the background and the
# text becomes genuinely hard to read. SGR 2 instead reduces the intensity of
# the theme's own foreground, so it stays proportional on light and dark alike —
# and a terminal that doesn't implement it renders the line at full contrast,
# which is the right way to fail. Legible beats distinguishable.

# shellcheck shell=bash

# Colour only when writing to a TTY — keep CI logs and pipes plain.
#
# c_cyan carries no use inside this file: it is consumed by ghosts.sh for the
# worktree label. Lint checks this file on its own too, where that reads as dead.
# shellcheck disable=SC2034
if [ -t 1 ]; then
    c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_yellow=$'\033[0;33m'
    c_cyan=$'\033[0;36m'
    c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
    c_green=''; c_red=''; c_yellow=''; c_cyan=''
    c_dim=''; c_bold=''; c_reset=''
fi

section() { printf '\n%s%s%s\n' "$c_bold" "$1" "$c_reset"; }

pass()    { printf '  %s✓%s %s\n' "$c_green"  "$c_reset" "$1"; }
warn()    { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$1"; }

# Data the reader came for — default foreground, never dim.
value()   { printf '    %s\n' "$1"; }

# An aside the reader can skip — dim by design.
detail()  { printf '    %s%s%s\n' "$c_dim" "$1" "$c_reset"; }

# Display-only: abbreviate $HOME to ~ so deep DerivedData paths stay scannable.
pretty_path() { printf '%s' "${1/#$HOME/~}"; }
