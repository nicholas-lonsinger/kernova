# The worktree layout the Tools/ scripts share. Sourced, never run:
#
#     . "$REPO_ROOT/Tools/lib/worktrees.sh"
#     read_worktree_layout "$REPO_ROOT" || …
#
# read_worktree_layout <checkout> sets
#
#   main_root       the primary checkout, which <checkout> is not when it is a
#                   linked worktree: `git worktree list` names the primary first
#   worktrees_root  $main_root/.claude/worktrees, where the linked worktrees live
#
# and records the registered worktrees for the queries below. When git cannot
# list the worktrees it returns 1 and leaves everything empty.

# shellcheck shell=bash

# The abandoned-worktree report below asks which processes hold a worktree.
# shellcheck source=holders.sh
. "$(dirname "${BASH_SOURCE[0]}")/holders.sh"

read_worktree_layout() {
    local listing paths
    main_root=''
    worktrees_root=''
    worktree_paths=''
    worktree_listing=''
    listing=$(git -C "$1" worktree list --porcelain 2>/dev/null) || return 1
    paths=$(sed -n 's/^worktree //p' <<<"$listing")
    [ -n "$paths" ] || return 1
    worktree_paths=$paths
    main_root=${paths%%$'\n'*}
    worktrees_root="$main_root/.claude/worktrees"
    worktree_listing=$listing
}

# worktree_registered <dir> — whether a `git worktree list` entry names <dir>.
# Compared by identity (same device and inode), not by spelling: git records
# each path resolved, and a caller that trashes what is not registered must
# still match a registered directory reached through a symlink.
worktree_registered() {
    local wt
    while IFS= read -r wt; do
        [ -n "$wt" ] && [ "$1" -ef "$wt" ] && return 0
    done <<<"$worktree_paths"
    return 1
}

# orphaned_worktree_dirs — one line per directory directly under worktrees_root
# that no registration names; files and symlinks are skipped. Reports nothing
# when the listing could not be read, where every directory would otherwise
# look unregistered.
orphaned_worktree_dirs() {
    [ -n "$worktrees_root" ] || return 0
    local dir
    for dir in "$worktrees_root"/*/; do
        dir=${dir%/}
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            continue
        fi
        worktree_registered "$dir" || printf '%s\n' "$dir"
    done
}

# worktree_field <worktree> <key> — the rest of the <key> line in <worktree>'s
# `git worktree list --porcelain` record (empty for a bare `locked`); returns 1
# when the record has no such line.
#
# The listing is a here-string, never a pipe, throughout this file: under
# pipefail a consumer that exits early (awk's `exit`, `grep -q`) leaves the
# producer to die of SIGPIPE once the text outgrows the pipe buffer, and the
# pipeline's failure then reads as the answer.
worktree_field() {
    WANT=$1 KEY=$2 awk '
        /^worktree / { cur = substr($0, 10); next }
        cur == ENVIRON["WANT"] {
            key = ENVIRON["KEY"]
            if ($0 == key) { found = 1; exit }
            if (index($0, key " ") == 1) { print substr($0, length(key) + 2); found = 1; exit }
        }
        END { exit !found }
    ' <<<"$worktree_listing"
}

# ---- abandoned worktrees -------------------------------------------------------
#
# A registered worktree directly under worktrees_root is abandoned when no live
# Claude Code session owns it, it holds no uncommitted work, and its HEAD's
# content is already on default_ref. Every answer these checks cannot reach
# reads as "keep". Whether a process still uses it is asked separately
# (holders.sh), so a held worktree can be reported with its holders.

default_ref=refs/remotes/origin/main

# The lock reason Claude Code writes for a live session or subagent. The pid is
# the owning session's; `start` is that process's start time, in the C locale
# and UTC, which tells a reused pid apart.
claude_lock_pattern='^claude (session|agent) [^ ]+ \(pid ([0-9]+) start ([^()]+)\)$'

squeeze_spaces() { awk '{ $1 = $1; print }' <<<"$1"; }

# utc_epoch <time> — <time> in the C-locale `ps -o lstart` form, read as UTC,
# printed as epoch seconds; returns 1 when it does not parse exactly.
utc_epoch() {
    local out
    out=$(LC_ALL=C TZ=UTC date -j -u -f '%a %b %d %T %Y' "$(squeeze_spaces "$1")" +%s 2>&1) || return 1
    case "$out" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$out"
}

# pid_gone <pid> — only a "no such process" answer counts; a pid kill may not
# signal still exists.
pid_gone() {
    local out
    out=$(LC_ALL=C /bin/kill -0 "$1" 2>&1) && return 1
    case "$out" in
        *'No such process'*) return 0 ;;
    esac
    return 1
}

# claude_lock_stale <reason> — 0 only when <reason> is a Claude Code lock whose
# owner is gone: no process has its pid, or both start times parse and the
# process with that pid started after the lock's owner did, as a reused pid
# must. ps prints lstart in the caller's locale, so it runs under LC_ALL=C.
claude_lock_stale() {
    [[ $1 =~ $claude_lock_pattern ]] || return 1
    local pid=${BASH_REMATCH[2]} start=${BASH_REMATCH[3]} locked_at started_at
    pid_gone "$pid" && return 0
    locked_at=$(utc_epoch "$start") || return 1
    started_at=$(utc_epoch "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null)") || return 1
    [ "$started_at" -gt "$locked_at" ]
}

# worktree_clean <worktree> — no staged, unstaged, or untracked non-ignored
# change. Untracked files are asked for explicitly: status.showUntrackedFiles=no
# would otherwise hide them. No optional locks: a plain status takes the
# worktree's index.lock to refresh it, which can fail a git command running
# there.
worktree_clean() {
    local st
    st=$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=normal 2>/dev/null) || return 1
    [ -z "$st" ]
}

# content_on_default <commit-ish> — some first-parent commit of default_ref,
# from the merge base with <commit-ish> forward, is one that merging
# <commit-ish> into changes nothing. A squash-merged branch passes even after
# later commits on default_ref edit the same lines; content no such commit
# ever held fails.
#
# Only the merge bases and the commits touching a path <commit-ish> changes
# are tried: that merge's result depends on no other path, so a commit that
# touches none of them answers exactly as the last one before it that did.
content_on_default() {
    local bases base changed paths candidates c
    bases=$(git -C "$main_root" merge-base --all "$default_ref" "$1" 2>/dev/null) || return 1
    [ -n "$bases" ] || return 1
    # A path git has to quote (a newline in its name) matches no literal
    # pathspec, which only drops candidates, and so only keeps.
    paths=''
    while IFS= read -r base; do
        changed=$(git -c core.quotePath=false -C "$main_root" diff --no-renames --name-only "$base" "$1" 2>/dev/null) || return 1
        [ -n "$changed" ] && paths+="$changed"$'\n'
    done <<<"$bases"
    candidates=''
    if [ -n "$paths" ]; then
        # shellcheck disable=SC2086 # one object name per word
        candidates=$(sort -u <<<"${paths%$'\n'}" | tr '\n' '\0' |
            xargs -0 git --literal-pathspecs -C "$main_root" rev-list --first-parent --reverse \
                "$default_ref" --not $bases -- 2>/dev/null) || return 1
    fi
    while IFS= read -r c; do
        [ -n "$c" ] && merge_changes_nothing "$c" "$1" && return 0
    done <<<"$bases
$candidates"
    return 1
}

# merge_changes_nothing <base> <commit-ish> — merging <commit-ish> into <base>
# cleanly yields <base>'s own tree.
merge_changes_nothing() {
    local tree merged
    tree=$(git -C "$main_root" rev-parse --verify -q "$1^{tree}") || return 1
    merged=$(git -C "$main_root" merge-tree --write-tree "$1" "$2" 2>/dev/null) || return 1
    [ "${merged%%$'\n'*}" = "$tree" ]
}

# worktree_unhidden <worktree> — no index entry marked skip-worktree or
# assume-unchanged, and no sparse checkout: edits behind either are invisible
# to `git status`.
worktree_unhidden() {
    local flags sparse
    flags=$(git --no-optional-locks -C "$1" ls-files -v 2>/dev/null) || return 1
    grep -q '^[a-zS] ' <<<"$flags" && return 1
    sparse=$(git -C "$1" config --bool core.sparseCheckout 2>/dev/null)
    [ "$sparse" != true ]
}

# worktree_abandoned <worktree> <own> — never the primary checkout, <own> (the
# checkout running the scan), or anything not directly under worktrees_root.
# Sets abandoned_stale_lock to the stale Claude Code lock it looked past, or
# '', and abandoned_head to the commit whose content it verified.
worktree_abandoned() {
    local wt=$1 own=$2 reason head
    abandoned_stale_lock=''
    abandoned_head=''
    [ -n "$worktrees_root" ] && [ -n "$own" ] && [ -d "$wt" ] || return 1
    [ "$wt" -ef "$main_root" ] && return 1
    [ "$wt" -ef "$own" ] && return 1
    [ "$(dirname "$wt")" -ef "$worktrees_root" ] || return 1
    if reason=$(worktree_field "$wt" locked); then
        claude_lock_stale "$reason" || return 1
        abandoned_stale_lock=$reason
    fi
    worktree_clean "$wt" && worktree_unhidden "$wt" || return 1
    head=$(git -C "$wt" rev-parse --verify -q HEAD) || return 1
    content_on_default "$head" || return 1
    abandoned_head=$head
}

# abandoned_worktrees <own> — one line per registered worktree that is
# abandoned.
abandoned_worktrees() {
    local wt
    while IFS= read -r wt; do
        [ -n "$wt" ] && worktree_abandoned "$wt" "$1" && printf '%s\n' "$wt"
    done <<<"$worktree_paths"
}

# worktree_admin_dir <worktree> — git's administrative directory for
# <worktree>, printed only when <worktree>/.git names it, it sits directly in
# the common dir's worktrees/, and its gitdir file names <worktree>/.git back.
worktree_admin_dir() {
    local wt=$1 admin common recorded
    [ -f "$wt/.git" ] || return 1
    admin=$(sed -n 's/^gitdir: //p' "$wt/.git")
    [ -n "$admin" ] && [ -d "$admin" ] && [ ! -L "$admin" ] || return 1
    common=$(git -C "$main_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [ "$(dirname "$admin")" -ef "$common/worktrees" ] || return 1
    recorded=$(cat "$admin/gitdir" 2>/dev/null) || return 1
    [ -n "$recorded" ] && [ "$recorded" -ef "$wt/.git" ] || return 1
    printf '%s' "$admin"
}


# ---- report and repair -------------------------------------------------------------

# report_abandoned_worktrees <checkout> <fix> <holders> <dispose> — the ghosts
# report's section, scanning from <checkout>, which is never itself removed.
# Names each abandoned worktree; one the <holders> command claims (called with
# its path after refresh_holders, printing why it is held, or nothing — as
# holder_blocked_lines does) is named with those lines and kept. With
# <fix> = 1 the rest go through remove_abandoned_worktree. Prints through the
# caller's pass/warn/ghost/fixed/detail/pretty_path. Without default_ref there
# is nothing to judge content against, so it warns and names nothing.
report_abandoned_worktrees() {
    local checkout=$1 fix=$2 holders_of=$3 dispose=$4 own wt held line stopped=0 abandoned=()
    if ! own=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || [ -z "$own" ] ||
        ! read_worktree_layout "$checkout"; then
        warn 'Skipped the abandoned-worktree check: `git worktree list` could not be read'
        return 0
    fi
    if ! git -C "$main_root" rev-parse --verify -q "$default_ref" >/dev/null; then
        warn "Skipped the abandoned-worktree check: ${default_ref#refs/remotes/} does not resolve"
        return 0
    fi
    while IFS= read -r wt; do
        abandoned+=("$wt")
    done < <(abandoned_worktrees "$own")
    if [ "${#abandoned[@]}" -eq 0 ]; then
        pass 'No abandoned worktrees under .claude/worktrees/'
        return 0
    fi
    refresh_holders "$worktrees_root"
    for wt in "${abandoned[@]}"; do
        held=$("$holders_of" "$wt")
        if [ -n "$held" ]; then
            ghost "Abandoned worktree, but in use: $(pretty_path "$wt")"
            while IFS= read -r line; do
                detail "$line"
            done <<<"$held"
            continue
        fi
        ghost "Abandoned worktree (clean, content on ${default_ref#refs/remotes/}): $(pretty_path "$wt")"
        [ "$fix" = 1 ] && [ "$stopped" = 0 ] || continue
        remove_abandoned_worktree "$checkout" "$own" "$wt" "$holders_of" "$dispose"
        case $? in
            0) fixed "trashed: $(pretty_path "$wt")${removed_branch:+, and deleted branch $removed_branch}" ;;
            1) detail "kept: $(pretty_path "$wt") no longer qualified, or could not be moved to the Trash" ;;
            2) detail "trashed $(pretty_path "$wt"), but its record under .git/worktrees/ could not be deleted" ;;
            *)
                detail "kept: $(pretty_path "$wt") — \`git worktree list\` could not be re-read, so nothing more is removed this run"
                stopped=1
                ;;
        esac
    done
}

# remove_abandoned_worktree <checkout> <own> <worktree> <holders> <dispose> —
# re-reads the layout from <checkout>, re-checks everything, then hands
# <worktree> to the <dispose> command (called with its path), which moves it
# out of place, and deletes git's administrative directory for it — that one,
# never a repository-wide prune. A stale Claude Code lock is lifted only for
# the removal, and restored when the directory stays. The worktree's
# `worktree-*` branch goes too when no other worktree has it checked out, it
# still points where it did, and its content is on default_ref. Returns 0
# removed, 1 kept, 2 moved but its record left, 3 kept because the layout could
# not be re-read; sets removed_branch to the deleted branch, or ''. Re-reads
# the layout globals.
remove_abandoned_worktree() {
    local checkout=$1 own=$2 wt=$3 holders_of=$4 dispose=$5 lock head branch admin listing tip now_locked
    removed_branch=''
    [ -n "$checkout" ] && [ -n "$own" ] || return 3
    read_worktree_layout "$checkout" || return 3
    # The slow checks — content, then the process snapshot — come first; after
    # the snapshot only file reads and fast git queries run before the move.
    worktree_abandoned "$wt" "$own" || return 1
    lock=$abandoned_stale_lock
    head=$abandoned_head
    branch=$(worktree_field "$wt" branch) || branch=''
    admin=$(worktree_admin_dir "$wt") || return 1
    refresh_holders "$worktrees_root"
    [ -z "$("$holders_of" "$wt")" ] || return 1
    # The lock as it stands now: still the stale one, or still none.
    if [ -z "$lock" ]; then
        [ ! -e "$admin/locked" ] || return 1
    else
        now_locked=$(cat "$admin/locked" 2>/dev/null) || return 1
        [ "$now_locked" = "$lock" ] || return 1
        git -C "$main_root" worktree unlock "$wt" >/dev/null 2>&1 || return 1
    fi
    if [ "$(git -C "$wt" rev-parse --verify -q HEAD)" != "$head" ] ||
        ! worktree_clean "$wt" || ! worktree_unhidden "$wt"; then
        [ -n "$lock" ] && git -C "$main_root" worktree lock --reason "$lock" "$wt" >/dev/null 2>&1
        return 1
    fi
    "$dispose" "$wt"
    if [ -e "$wt" ]; then
        [ -n "$lock" ] && git -C "$main_root" worktree lock --reason "$lock" "$wt" >/dev/null 2>&1
        return 1
    fi
    rm -rf "$admin"
    [ -e "$admin" ] && return 2
    case "$branch" in
        refs/heads/worktree-*) ;;
        *) return 0 ;;
    esac
    listing=$(git -C "$checkout" worktree list --porcelain 2>/dev/null) || return 0
    grep -qxF "branch $branch" <<<"$listing" && return 0
    tip=$(git -C "$main_root" rev-parse --verify -q "$branch") || return 0
    [ "$tip" = "$head" ] || content_on_default "$tip" || return 0
    # Deleted only if it still points at the commit just verified.
    # shellcheck disable=SC2034 # read by the caller
    git -C "$main_root" update-ref -d "$branch" "$tip" >/dev/null 2>&1 || return 0
    removed_branch=${branch#refs/heads/}
    # update-ref leaves the branch's config (the upstream `push -u` set), which
    # a later branch of the same name would inherit. None at all is fine.
    git -C "$main_root" config --remove-section "branch.$removed_branch" >/dev/null 2>&1
    return 0
}
