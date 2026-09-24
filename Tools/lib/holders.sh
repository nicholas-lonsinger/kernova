# Which processes hold a path. Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/holders.sh"
#     refresh_holders "$dir"
#     holder_blocked_lines "$dir"
#
# A process holds a path when its working directory, an open file, or a mapped
# binary sits under it (one lsof over every process), or when its command line
# names it (one ps). Both come from a snapshot refresh_holders takes; the
# queries read that snapshot.

# shellcheck shell=bash

# refresh_holders <dir>... — snapshot what every process holds under any
# <dir>, spelled as given or resolved. holders_read says whether both listings
# came back at all. lsof runs with -b so a stale network mount cannot block it
# in the kernel.
refresh_holders() {
    local d r files procs prefixes=''
    for d in "$@"; do
        prefixes+="$d"$'\n'
        r=$(cd "$d" 2>/dev/null && pwd -P) && [ "$r" != "$d" ] && prefixes+="$r"$'\n'
    done
    files=$(lsof +c 0 -b -w -n -Fpcfn 2>/dev/null)
    # comm is a fixed 16-column field (MAXCOMLEN) when it is not the last one.
    procs=$(ps -axo pid=,ppid=,comm=,args= 2>/dev/null)
    holders_read=0
    [ -n "$files" ] && [ -n "$procs" ] && holders_read=1
    holder_files=$(PREFIXES=$prefixes awk '
        function held(n,   i) {
            for (i = 1; i <= np; i++) if (n == pre[i] || index(n, pre[i] "/") == 1) return 1
            return 0
        }
        BEGIN { np = split(ENVIRON["PREFIXES"], all, "\n"); for (i = 1; i <= np; i++) if (all[i] != "") pre[++k] = all[i]; np = k }
        /^p/ { p = substr($0, 2) }
        /^c/ { c = substr($0, 2) }
        /^f/ { f = substr($0, 2) }
        /^n/ { n = substr($0, 2); if (held(n)) print p "\t" c "\t" f "\t" n }
    ' <<<"$files")
    # This shell and its subshells are left out: a caller's own arguments name
    # the path it asks about. A command line names a path when the path is
    # followed by `/` or ends an argument (`code <dir>`, `git -C <dir> …`).
    holder_procs=$(PREFIXES=$prefixes SELF=$$ awk '
        function mine(p,   n) {
            for (n = 0; p != "" && p > 1 && n < 64; n++) { if (p == ENVIRON["SELF"]) return 1; p = parent[p] }
            return 0
        }
        function names(s, d) { return index(s, d "/") || index(s " ", d " ") }
        BEGIN { np = split(ENVIRON["PREFIXES"], all, "\n"); for (i = 1; i <= np; i++) if (all[i] != "") pre[++k] = all[i]; np = k }
        { line[NR] = $0; pid[NR] = $1; parent[$1] = $2 }
        END {
            for (r = 1; r <= NR; r++) {
                if (mine(pid[r])) continue
                for (i = 1; i <= np; i++) if (names(line[r], pre[i])) {
                    rest = line[r]; sub(/^ *[0-9]+ +[0-9]+ /, "", rest)
                    comm = substr(rest, 1, 16); sub(/ +$/, "", comm)
                    print pid[r] "\t" comm "\t" substr(rest, 18)
                    break
                }
            }
        }
    ' <<<"$procs")
}

# path_holders <dir> — one `<pid> TAB <command> TAB <kind>` line per process
# holding <dir> in the last snapshot, <kind> being `running` when a binary it
# has mapped lies inside, else `open`. <dir> must fall under a directory the
# snapshot was taken for.
path_holders() {
    local real
    real=$(cd "$1" 2>/dev/null && pwd -P) || real=$1
    {
        DIR=$1 REAL=$real awk -F '\t' '
            function under(p, d) { return p == d || index(p, d "/") == 1 }
            under($4, ENVIRON["DIR"]) || under($4, ENVIRON["REAL"]) {
                print $1 "\t" $2 "\t" ($3 == "txt" ? "running" : "open")
            }
        ' <<<"$holder_files"
        DIR=$1 REAL=$real awk -F '\t' '
            function names(s, d) { return index(s, d "/") || index(s " ", d " ") }
            names($3, ENVIRON["DIR"]) || names($3, ENVIRON["REAL"]) { print $1 "\t" $2 "\topen" }
        ' <<<"$holder_procs"
    } | sort -t "$(printf '\t')" -k1,1n -k3,3r | awk -F '\t' '$1 != last { print; last = $1 }'
}

# path_held <dir> — whether anything holds <dir>, or the snapshot could not be
# taken, in which case nothing may assume it is free.
path_held() {
    [ "${holders_read:-0}" = 1 ] || return 0
    [ -n "$(path_holders "$1")" ]
}

# holder_blocked_lines <dir> — why <dir> cannot go: each holder, how to clear
# them, and Kernova's own quit command when the app is among them. Prints
# nothing when nothing holds it. Capped at five holders with the rest counted:
# a build in flight holds its arena through every swift-frontend and ld.
#
# `running` holders die with the eviction; `open` ones — a build tool, a log
# tail, a shell sitting in it — only lose their path, which sends the reader
# after a different process.
holder_blocked_lines() {
    local dir=$1 pid cmd kind shown=0 total=0 max=5 holders
    if [ "${holders_read:-0}" != 1 ]; then
        printf 'unknown: the process table could not be read\n'
        return
    fi
    holders=$(path_holders "$dir")
    [ -n "$holders" ] || return 0
    while IFS=$'\t' read -r pid cmd kind; do
        total=$((total + 1))
        [ "$shown" -ge "$max" ] && continue
        shown=$((shown + 1))
        if [ "$kind" = running ]; then
            printf 'running from inside: PID %s (%s)\n' "$pid" "${cmd:-?}"
        else
            printf 'holding it open: PID %s (%s)\n' "$pid" "${cmd:-?}"
        fi
    done <<<"$holders"
    [ "$total" -gt "$shown" ] && printf 'and %s more\n' "$((total - shown))"
    if [ "$total" -gt 1 ]; then
        printf 'quit them (or reboot), then re-run\n'
    else
        printf 'quit it (or reboot), then re-run\n'
    fi
    # Additive, never instead of the line above: with a mixed set, quitting the
    # app alone leaves the path held and the next run refusing identically.
    if DIR=$dir awk -F '\t' '
        $3 == "txt" && index($4, ENVIRON["DIR"] "/") == 1 && $4 ~ /\/Kernova\.app\/Contents\/MacOS\/Kernova$/ { f = 1 }
        END { exit !f }
    ' <<<"$holder_files"; then
        printf 'Kernova quits cleanly with: %s (save-suspends running VMs)\n' \
            "osascript -e 'quit app \"Kernova\"'"
    fi
}
