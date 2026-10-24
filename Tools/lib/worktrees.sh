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

# stale_build_server_caches <cache root> — one line per xcode-build-server
# cache folder under <cache root> that names this clone's primary checkout or
# a .claude/worktrees/ checkout, and no registered worktree. xcode-build-server
# names each folder for its checkout's absolute path with every `/` turned into
# `-` (its server.py, build_initialize), and nothing removes the folder with the
# checkout. The transform is lossy, so a folder is claimed only in this clone's
# own layout: the primary's name alone, or it followed by `-.claude-worktrees-`
# — a sibling project named `<primary>-foo` reads the same as a worktree
# outside that layout, and is left alone. Reports nothing when the listing
# could not be read, where every folder would otherwise look stale.
stale_build_server_caches() {
    [ -n "$main_root" ] || return 0
    local prefix=${main_root//\//-} live='' wt dir
    while IFS= read -r wt; do
        [ -n "$wt" ] && live+="${wt//\//-}"$'\n'
    done <<<"$worktree_paths"
    for dir in "$1/$prefix" "$1/$prefix"-.claude-worktrees-*; do
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            continue
        fi
        grep -qxF -- "${dir##*/}" <<<"$live" || printf '%s\n' "$dir"
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
# Claude Code session owns it — none holds its lock and none runs inside it —,
# it holds no uncommitted work, and its HEAD is already on the remote: its
# content on default_ref, or every commit it adds held by one of the remote's
# branches or pull-request heads, as that commit or as one with the same patch.
# Every answer these checks cannot reach reads as "keep". Whether
# any other process still uses it is asked separately (holders.sh), so a held
# worktree can be reported with its holders.

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

# load_pull_heads — sets pull_heads to "<object> PR #<N>" lines for the
# pull-request heads of default_ref's remote, newest first, asking the remote
# once per main_root per run. GitHub keeps refs/pull/<N>/head after a merged
# PR's branch is deleted, so these still hold a worktree's commits once nothing
# else on the remote does. A remote that cannot be reached leaves it empty.
load_pull_heads() {
    local remote=${default_ref#refs/remotes/}
    [ "${pull_heads_root-}" = "$main_root" ] && return 0
    pull_heads_root=$main_root
    pull_heads=$(GIT_TERMINAL_PROMPT=0 git -C "$main_root" ls-remote "${remote%%/*}" 'refs/pull/*/head' 2>/dev/null |
        awk '{ n = $2; sub("^refs/pull/", "", n); sub("/head$", "", n); print $1, n }' |
        sort -k2,2nr | awk '{ print $1, "PR #" $2 }') || pull_heads=''
}

# remote_tips — "<object> <name>" for each of the remote's branches (as of the
# last fetch), then each of pull_heads, keeping only commits in the local object
# store: one missing object would fail a walk from all of them.
remote_tips() {
    local remote=${default_ref#refs/remotes/}
    {
        git -C "$main_root" for-each-ref --format='%(objectname) %(refname:lstrip=2)' "refs/remotes/${remote%%/*}" 2>/dev/null |
            awk '$2 !~ /\/HEAD$/'
        [ -z "$pull_heads" ] || printf '%s\n' "$pull_heads"
    } | git -C "$main_root" cat-file --batch-check='%(objecttype) %(objectname) %(rest)' 2>/dev/null |
        sed -n 's/^commit //p'
}

# tip_holding <commit> <tips> — the name of the first of <tips> (remote_tips
# lines) whose history holds <commit>.
tip_holding() {
    local object name
    while read -r object name; do
        git -C "$main_root" merge-base --is-ancestor "$1" "$object" 2>/dev/null && { printf '%s' "$name"; return 0; }
    done <<<"$2"
    return 1
}

# remote_holding <commit> — every commit <commit>'s history holds that no
# remote_tips ref does has the same patch as a commit one of them holds. Sets
# remote_holder to how: `HEAD on <tip>` when <commit> itself is held,
# `patches on <tip>, …` otherwise.
remote_holding() {
    local tips objects candidates missing c pid paths path pool match name names=''
    local -a pathspecs
    remote_holder=''
    load_pull_heads
    tips=$(remote_tips)
    [ -n "$tips" ] || return 1
    objects=$(cut -d ' ' -f 1 <<<"$tips")
    missing=$(git -C "$main_root" rev-list --stdin <<<"$1"$'\n--not\n'"$objects" 2>/dev/null) || return 1
    if [ -z "$missing" ]; then
        name=$(tip_holding "$1" "$tips") || return 1
        remote_holder="HEAD on $name"
        return 0
    fi
    # default_ref's own content is content_on_default's to judge.
    candidates=$objects
    if git -C "$main_root" rev-parse --verify -q "$default_ref" >/dev/null; then
        candidates+=$'\n--not\n'"$default_ref"
    fi
    while IFS= read -r c; do
        pid=$(git -C "$main_root" diff-tree -p --root "$c" 2>/dev/null | git -C "$main_root" patch-id --stable) || return 1
        pid=${pid%% *}
        # diff-tree prints no patch for a merge, so its resolution is never matched.
        [ -n "$pid" ] || return 1
        # A commit with the same patch changes the same paths.
        paths=$(git -c core.quotePath=false -C "$main_root" diff-tree --no-commit-id --no-renames --name-only -r --root "$c" 2>/dev/null) || return 1
        pathspecs=()
        while IFS= read -r path; do
            pathspecs+=("$path")
        done <<<"$paths"
        pool=$(git --literal-pathspecs -C "$main_root" rev-list --stdin --no-merges -- "${pathspecs[@]}" <<<"$candidates" 2>/dev/null) || return 1
        match=$(git -C "$main_root" diff-tree --stdin -p --root <<<"$pool" 2>/dev/null |
            git -C "$main_root" patch-id --stable | awk -v p="$pid" '!f && $1 == p { print $2; f = 1 }') || return 1
        [ -n "$match" ] || return 1
        name=$(tip_holding "$match" "$tips") || return 1
        case $'\n'"$names"$'\n' in
            *$'\n'"$name"$'\n'*) ;;
            *) names+="${names:+$'\n'}$name" ;;
        esac
    done <<<"$missing"
    remote_holder="patches on ${names//$'\n'/, }"
}

# held_by_remote <commit> — <commit>'s content is on default_ref, or
# remote_holding vouches for it. Sets remote_where to how.
held_by_remote() {
    remote_where=''
    if content_on_default "$1"; then
        remote_where="content on ${default_ref#refs/remotes/}"
        return 0
    fi
    remote_holding "$1" || return 1
    remote_where=$remote_holder
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
# '', abandoned_head to the commit it verified, and abandoned_where to how the
# remote holds it.
worktree_abandoned() {
    local wt=$1 own=$2 reason head
    abandoned_stale_lock=''
    abandoned_head=''
    abandoned_where=''
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
    held_by_remote "$head" || return 1
    abandoned_where=$remote_where
    abandoned_head=$head
}

# claude_session_in <worktree> — whether, in the last holders snapshot, a
# process named `claude` has its working directory inside <worktree>. That is a
# live Claude Code session whether or not it locked the worktree: a Claude
# desktop app session runs in one it never locked.
claude_session_in() {
    local real
    real=$(cd "$1" 2>/dev/null && pwd -P) || real=$1
    DIR=$1 REAL=$real awk -F '\t' '
        function under(p, d) { return p == d || index(p, d "/") == 1 }
        $2 == "claude" && $3 == "cwd" && (under($4, ENVIRON["DIR"]) || under($4, ENVIRON["REAL"])) { f = 1 }
        END { exit !f }
    ' <<<"${holder_files:-}"
}

# abandoned_worktrees <own> — sets abandoned to the registered worktrees that
# are abandoned, and abandoned_wheres to each one's abandoned_where. When any
# worktree passes worktree_abandoned, it takes the holders snapshot that rules
# out a running session, and leaves it for the caller's holder queries.
abandoned_worktrees() {
    local wt i candidates=() wheres=()
    abandoned=()
    abandoned_wheres=()
    while IFS= read -r wt; do
        if [ -n "$wt" ] && worktree_abandoned "$wt" "$1"; then
            candidates+=("$wt")
            wheres+=("$abandoned_where")
        fi
    done <<<"$worktree_paths"
    [ "${#candidates[@]}" -gt 0 ] || return 0
    refresh_holders "$worktrees_root"
    for i in "${!candidates[@]}"; do
        if ! claude_session_in "${candidates[$i]}"; then
            abandoned+=("${candidates[$i]}")
            abandoned_wheres+=("${wheres[$i]}")
        fi
    done
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
# its path against abandoned_worktrees' snapshot, printing why it is held, or
# nothing — as holder_blocked_lines does) is named with those lines and kept.
# With <fix> = 1 the rest go through remove_abandoned_worktree. Prints through the
# caller's pass/warn/ghost/fixed/detail/pretty_path/disk_size. Without default_ref
# there is nothing to judge content against, so it warns and names nothing.
report_abandoned_worktrees() {
    local checkout=$1 fix=$2 holders_of=$3 dispose=$4 own wt i held line stopped=0 abandoned abandoned_wheres
    if ! own=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || [ -z "$own" ] ||
        ! read_worktree_layout "$checkout"; then
        warn 'Skipped the abandoned-worktree check: `git worktree list` could not be read'
        return 0
    fi
    if ! git -C "$main_root" rev-parse --verify -q "$default_ref" >/dev/null; then
        warn "Skipped the abandoned-worktree check: ${default_ref#refs/remotes/} does not resolve"
        return 0
    fi
    abandoned_worktrees "$own"
    if [ "${#abandoned[@]}" -eq 0 ]; then
        pass 'No abandoned worktrees under .claude/worktrees/'
        return 0
    fi
    for i in "${!abandoned[@]}"; do
        wt=${abandoned[$i]}
        held=$("$holders_of" "$wt")
        if [ -n "$held" ]; then
            ghost "Abandoned worktree, but in use: $(pretty_path "$wt") — $(disk_size "$wt")"
            while IFS= read -r line; do
                detail "$line"
            done <<<"$held"
            continue
        fi
        ghost "Abandoned worktree (clean, ${abandoned_wheres[$i]}): $(pretty_path "$wt") — $(disk_size "$wt")"
        [ "$fix" = 1 ] && [ "$stopped" = 0 ] || continue
        remove_abandoned_worktree "$checkout" "$own" "$wt" "$holders_of" "$dispose"
        case $? in
            0) fixed "trashed: $(pretty_path "$wt")" ;;
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
# the removal, and restored when the directory stays. Its branch is left to
# report_orphaned_branches. Returns 0 removed, 1 kept, 2 moved but its record
# left, 3 kept because the layout could not be re-read. Re-reads the layout
# globals.
remove_abandoned_worktree() {
    local checkout=$1 own=$2 wt=$3 holders_of=$4 dispose=$5 lock head admin now_locked
    [ -n "$checkout" ] && [ -n "$own" ] || return 3
    read_worktree_layout "$checkout" || return 3
    # The slow checks — content, then the process snapshot — come first; after
    # the snapshot only file reads and fast git queries run before the move.
    worktree_abandoned "$wt" "$own" || return 1
    lock=$abandoned_stale_lock
    head=$abandoned_head
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
    return 0
}

# orphaned_worktree_branches — sets orphaned_branches to the `worktree-*`
# branches (refs/heads/…) no registered worktree has checked out whose tip
# held_by_remote vouches for, and orphaned_branch_tips and
# orphaned_branch_wheres to each one's tip and remote_where.
orphaned_worktree_branches() {
    local branch tip refs
    orphaned_branches=()
    orphaned_branch_tips=()
    orphaned_branch_wheres=()
    refs=$(git -C "$main_root" for-each-ref --format='%(refname) %(objectname)' 'refs/heads/worktree-*' 2>/dev/null) || return 0
    while read -r branch tip; do
        [ -n "$branch" ] || continue
        grep -qxF "branch $branch" <<<"$worktree_listing" && continue
        held_by_remote "$tip" || continue
        orphaned_branches+=("$branch")
        orphaned_branch_tips+=("$tip")
        orphaned_branch_wheres+=("$remote_where")
    done <<<"$refs"
}

# delete_orphaned_branch <checkout> <branch> <tip> — deletes <branch> only while
# the layout re-read from <checkout> shows no worktree has it checked out and it
# still points at <tip>, and with it the upstream config `git push -u` records,
# which a later branch of the same name would inherit. Returns 1 when kept.
delete_orphaned_branch() {
    read_worktree_layout "$1" || return 1
    grep -qxF "branch $2" <<<"$worktree_listing" && return 1
    git -C "$main_root" update-ref -d "$2" "$3" >/dev/null 2>&1 || return 1
    git -C "$main_root" config --remove-section "branch.${2#refs/heads/}" >/dev/null 2>&1
    return 0
}

# report_orphaned_branches <checkout> <fix> — the ghosts report's section for
# orphaned_worktree_branches, read from <checkout>; with <fix> = 1 each goes
# through delete_orphaned_branch. Prints through the caller's
# pass/warn/ghost/fixed/detail. Without default_ref it warns and names nothing,
# as report_abandoned_worktrees does.
report_orphaned_branches() {
    local checkout=$1 fix=$2 i name orphaned_branches orphaned_branch_tips orphaned_branch_wheres
    if ! read_worktree_layout "$checkout"; then
        warn 'Skipped the orphaned-branch check: `git worktree list` could not be read'
        return 0
    fi
    if ! git -C "$main_root" rev-parse --verify -q "$default_ref" >/dev/null; then
        warn "Skipped the orphaned-branch check: ${default_ref#refs/remotes/} does not resolve"
        return 0
    fi
    orphaned_worktree_branches
    if [ "${#orphaned_branches[@]}" -eq 0 ]; then
        pass 'No orphaned worktree-* branches'
        return 0
    fi
    for i in "${!orphaned_branches[@]}"; do
        name=${orphaned_branches[$i]#refs/heads/}
        ghost "Orphaned worktree branch (${orphaned_branch_wheres[$i]}): $name"
        [ "$fix" = 1 ] || continue
        if delete_orphaned_branch "$checkout" "${orphaned_branches[$i]}" "${orphaned_branch_tips[$i]}"; then
            fixed "deleted branch $name"
        else
            detail "kept: $name is checked out again, or has moved"
        fi
    done
}
