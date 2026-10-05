#!/usr/bin/env bash
# Fixture tests for the after-merge skill: builds a bare "remote", a seeding
# clone that pushes to it, and a primary clone with a worktree, then drives
# after-merge.sh from inside the worktree through every verdict. Local git
# only — no network — and it takes a few seconds. Run it after editing the
# skill.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$ROOT/.agents/skills/after-merge/after-merge.sh"

if [ -t 1 ]; then c_green=$'\033[0;32m'; c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_green=''; c_red=''; c_reset=''; fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

# git reports worktree paths resolved, so resolve the fixture root the same way
# (on macOS mktemp answers under /var, a symlink to /private/var).
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# Pin everything git reads from the environment, so the run reports on the
# script and not on this machine's identity, global config, or caller.
#
# The repo-locating variables come first: git exports GIT_DIR, GIT_WORK_TREE
# and their companions to a hook's child processes, so a run under `pre-push`
# inherits them and every fixture command addresses the real checkout — each
# verdict then reports on that repo, not on the fixture the check built.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_PREFIX \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_QUARANTINE_PATH GIT_REFLOG_ACTION
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

git init -q --bare -b main "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/seed" 2>/dev/null
git -C "$tmp/seed" switch -q -c main 2>/dev/null || git -C "$tmp/seed" checkout -q -b main 2>/dev/null
seed_commit() { # <text>
    printf '%s\n' "$1" >"$tmp/seed/file"
    git -C "$tmp/seed" add file && git -C "$tmp/seed" commit -q -m "$1" && git -C "$tmp/seed" push -q origin main 2>/dev/null
}
seed_commit A
git clone -q "$tmp/remote.git" "$tmp/local" 2>/dev/null
git -C "$tmp/local" worktree add -q -b topic "$tmp/local/wt" 2>/dev/null
cd "$tmp/local/wt" || exit 1

# run <name> <expected-exit> <expected-verdict-regex> [args...]
run() {
    local name="$1" want_exit="$2" want="$3"; shift 3
    local out code
    out="$("$SCRIPT" "$@" 2>/dev/null)"; code=$?
    [ "$code" -eq "$want_exit" ] || fail "$name: exit $code, wanted $want_exit"
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "$name: stdout is not exactly one line: $out"
    if printf '%s' "$out" | grep -qE "$want"; then pass; else fail "$name: got '$out', wanted /$want/"; fi
}
local_main() { git -C "$tmp/local" rev-parse main; }
remote_main() { git -C "$tmp/seed" rev-parse main; }

run "current" 0 '^after-merge: verdict=current branch=main worktree=current$'

seed_commit B
run "fast-forwarded" 0 "^after-merge: verdict=fast-forwarded branch=main path=$tmp/local worktree=reset\$"
if [ "$(local_main)" = "$(remote_main)" ]; then pass; else fail "fast-forwarded: local main is not at the remote tip"; fi

seed_commit C
printf 'local edit\n' >"$tmp/local/file"
run "dirty" 0 "^after-merge: verdict=dirty branch=main path=$tmp/local files=file worktree=reset\$"
if [ "$(local_main)" != "$(remote_main)" ]; then pass; else fail "dirty: the branch moved despite local changes"; fi

# An edit to a file the incoming commits leave alone does not block, and so
# is never listed.
printf 'unrelated\n' >"$tmp/seed/other"
git -C "$tmp/seed" add other && git -C "$tmp/seed" commit -q -m "other" && git -C "$tmp/seed" push -q origin main 2>/dev/null
run "discard not blocking" 1 "^after-merge: verdict=setup-error reason=not-blocking path=other files=file\$" --discard other
if [ "$(local_main)" != "$(remote_main)" ]; then pass; else fail "discard not blocking: the branch moved"; fi
if [ "$(cat "$tmp/local/file")" = "local edit" ]; then pass; else fail "discard not blocking: the edit was discarded anyway"; fi

run "discard" 0 "^after-merge: verdict=fast-forwarded branch=main path=$tmp/local discarded=file worktree=reset\$" --discard file
if [ "$(local_main)" = "$(remote_main)" ]; then pass; else fail "discard: local main is not at the remote tip"; fi

# An untracked file the merge would create blocks too, and --discard cannot
# restore what HEAD never had.
seed_commit F
printf 'incoming\n' >"$tmp/seed/new"
git -C "$tmp/seed" add new && git -C "$tmp/seed" commit -q -m "new" && git -C "$tmp/seed" push -q origin main 2>/dev/null
printf 'untracked\n' >"$tmp/local/new"
run "dirty untracked" 0 "^after-merge: verdict=dirty branch=main path=$tmp/local files=new worktree=reset\$"
run "discard untracked" 1 '^after-merge: verdict=setup-error reason=discard-failed path=new$' --discard new
rm "$tmp/local/new"
run "clean again" 0 '^after-merge: verdict=fast-forwarded .* worktree=current$'

seed_commit G
printf 'local edit\n' >"$tmp/local/file"
git -C "$tmp/local" rev-parse HEAD >"$tmp/local/.git/MERGE_HEAD"
run "in progress" 0 "^after-merge: verdict=dirty branch=main path=$tmp/local reason=in-progress worktree=reset\$"
rm "$tmp/local/.git/MERGE_HEAD"
git -C "$tmp/local" checkout -q -- file
run "clean after in progress" 0 '^after-merge: verdict=fast-forwarded .* worktree=current$'

printf 'local commit\n' >"$tmp/local/file"
git -C "$tmp/local" commit -q -am "local D"
seed_commit E
run "diverged" 0 "^after-merge: verdict=diverged branch=main path=$tmp/local worktree=reset\$"
git -C "$tmp/local" reset -q --hard origin/main

git -C "$tmp/local" checkout -q --detach
run "not-checked-out" 0 '^after-merge: verdict=not-checked-out branch=main worktree=current$'
git -C "$tmp/local" checkout -q main

# The worktree's own branch. Two topic commits the remote never gets; the
# squash merge arrives as one seed commit carrying the same content.
wt_head() { git -C "$tmp/local/wt" rev-parse HEAD; }
printf 'one\n' >"$tmp/local/wt/feature"
git -C "$tmp/local/wt" add feature && git -C "$tmp/local/wt" commit -q -m "feature one"
printf 'one\ntwo\n' >"$tmp/local/wt/feature"
git -C "$tmp/local/wt" commit -q -am "feature two"
topic_before=$(wt_head)
run "worktree unmerged" 0 '^after-merge: verdict=current branch=main worktree=unmerged$'
if [ "$(wt_head)" = "$topic_before" ]; then pass; else fail "worktree unmerged: the branch moved"; fi

cp "$tmp/local/wt/feature" "$tmp/seed/feature"
git -C "$tmp/seed" add feature && git -C "$tmp/seed" commit -q -m "feature (squash)" && git -C "$tmp/seed" push -q origin main 2>/dev/null

printf 'uncommitted\n' >>"$tmp/local/wt/feature"
run "worktree dirty" 0 "^after-merge: verdict=fast-forwarded branch=main path=$tmp/local worktree=dirty\$"
if [ "$(wt_head)" = "$topic_before" ]; then pass; else fail "worktree dirty: the branch moved"; fi
git -C "$tmp/local/wt" checkout -q -- feature

git -C "$tmp/local/wt" checkout -q --detach
run "worktree detached" 0 '^after-merge: verdict=current branch=main worktree=none$'
git -C "$tmp/local/wt" checkout -q topic

run "worktree reset" 0 '^after-merge: verdict=current branch=main worktree=reset$'
if [ "$(git -C "$tmp/local/wt" rev-parse topic)" = "$(remote_main)" ]; then pass; else fail "worktree reset: topic is not at the remote tip"; fi
run "worktree current" 0 '^after-merge: verdict=current branch=main worktree=current$'

cd "$tmp/local" || exit 1
run "worktree primary" 0 '^after-merge: verdict=current branch=main worktree=none$'
cd "$tmp/local/wt" || exit 1

run "bad remote" 1 '^after-merge: verdict=setup-error reason=fetch-failed remote=nope$' --remote nope
run "bad argument" 1 '^after-merge: verdict=setup-error reason=usage argument=--bogus$' --bogus
mkdir -p "$tmp/empty"; cd "$tmp/empty" || exit 1
run "not a repository" 1 '^after-merge: verdict=setup-error reason=not-a-repository$'

if [ "$FAIL" -eq 0 ]; then
    printf '  %s✓%s after-merge: %d fixture checks\n' "$c_green" "$c_reset" "$PASS"
else
    printf '\n%d of %d fixture checks failed\n' "$FAIL" "$((PASS + FAIL))"
fi
[ "$FAIL" -eq 0 ]
