#!/usr/bin/env bash
# wait-github-ci.sh — block until a pull request's CI is verifiably green.
#
# Encodes the full wait-for-green choreography so callers never improvise it:
#   1. Pin the expected head SHA and wait for the PR to report it. If the PR
#      head disagrees, ask the git remote directly (`git ls-remote`) whether
#      the push actually landed — a push that never reached the remote fails
#      fast (exit 4) instead of timing out, while a landed push whose API
#      view is lagging keeps waiting.
#   2. Wait until the expected checks are actually registered for that SHA
#      (a watch started too early sees no/partial checks: false green). A PR
#      whose merge commit cannot be built (it conflicts with the base) never
#      registers pull_request-triggered checks at all — that is detected via
#      the PR's mergeable state and reported (exit 7) instead of being
#      indistinguishable from slow registration until the deadline.
#   3. Run one unpiped `gh pr checks --watch --fail-fast`.
#   4. Verify the final status rollup directly — the watch's exit code is
#      never trusted (it is 0 for "no checks yet" and for cancelled runs).
#
# The verdict gates on the base branch's REQUIRED checks (discovered from
# rulesets and legacy branch protection); if none are configured, it gates
# on ALL reported checks.
#
# Usage:
#   .agents/skills/wait-github-ci/wait-github-ci.sh [<pr-number>] [--sha <sha>] [--timeout <seconds>]
#                                                   [--repo <owner/repo>] [--remote <name>] [--verbose]
#
#   <pr-number>   PR to watch. Default: the PR for the current branch.
#   --sha         Head SHA the PR must be at. Default: git rev-parse HEAD,
#                 which is only right in the checkout the push came from; with
#                 an explicit <pr-number>, a checkout whose upstream is not the
#                 PR's head branch is refused rather than guessed at.
#   --timeout     Overall deadline in seconds (default 3600). On expiry the
#                 script exits 3; re-run it to keep waiting.
#   --repo        owner/repo (default: inferred from the working directory).
#   --remote      Git remote the PR's head branch lives on, used to verify the
#                 push actually landed (default origin).
#   --verbose     Also print the progress lines, for a person watching the
#                 script run in a terminal.
#
# Exit codes (merge only on 0):
#   0  verified green on the expected head SHA — safe to merge
#   1  usage or environment error (verdict=setup-error)
#   2  definitively not green (failed / cancelled / timed-out check)
#   3  deadline expired with checks still pending — re-run to keep waiting
#   4  the push never landed on the remote (or the PR head never became the
#      expected SHA) — push with an explicit refspec and re-run
#   5  PR head moved off the expected SHA mid-wait (a new push happened)
#   6  PR is not open (merged or closed)
#   7  the PR conflicts with its base, so its merge commit cannot be built
#      and pull_request-triggered checks will never register — rebase or
#      merge the base into the head branch, push, and re-run
#
# stderr carries the final `check status:` table, any `failing:` or `note:`
# lines, and the verdict message; --verbose adds the progress lines. The last
# stdout line is machine-readable:
#   wait-github-ci: verdict=<green|failed|pending|push-missing|...> pr=N sha=... elapsed=Ns

set -u

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

say() { printf 'wait-github-ci: %s\n' "$*" >&2; }

# Progress lines: printed only under --verbose.
progress() { [ "$VERBOSE" -eq 1 ] && say "$*"; return 0; }

finish() { # <exit-code> <verdict-word> [message]
  code="$1"; verdict="$2"; shift 2
  [ $# -gt 0 ] && say "$*"
  printf 'wait-github-ci: verdict=%s pr=%s sha=%s elapsed=%ss\n' \
    "$verdict" "${PR:-?}" "${EXPECTED_SHA:-?}" "$SECONDS"
  exit "$code"
}

PR=""
PR_GIVEN=0
EXPECTED_SHA=""
SHA_DEFAULTED=0
TIMEOUT=3600
REPO=""
REMOTE="origin"
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --sha) EXPECTED_SHA="${2:?--sha needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; finish 1 setup-error "unknown option: $1" ;;
    *) PR="$1"; PR_GIVEN=1; shift ;;
  esac
done

# Retry transient gh/network failures a few times before giving up.
ghq() {
  _i=0
  while [ "$_i" -lt 3 ]; do
    if _out=$(gh "$@" 2>/dev/null); then printf '%s\n' "$_out"; return 0; fi
    _i=$((_i + 1))
    sleep 5
  done
  return 1
}

# Join a newline-separated list into "a, b, c".
oneline() { printf '%s\n' "$1" | grep . | paste -sd ',' - | sed 's/,/, /g'; }

command -v gh >/dev/null 2>&1 || finish 1 setup-error "gh CLI not found"
[ -n "$REPO" ] && export GH_REPO="$REPO"

if [ -z "$PR" ]; then
  PR=$(ghq pr view --json number --jq .number) \
    || finish 1 setup-error "no PR number given and none resolvable from the current branch"
fi

if [ -z "$EXPECTED_SHA" ]; then
  EXPECTED_SHA=$(git rev-parse HEAD 2>/dev/null) \
    || finish 1 setup-error "not inside a git repository — pass --sha explicitly"
  SHA_DEFAULTED=1
else
  # Expand a short SHA when a repo is available; otherwise take it as-is.
  EXPECTED_SHA=$(git rev-parse "$EXPECTED_SHA" 2>/dev/null || printf '%s' "$EXPECTED_SHA")
fi

# The defaulted SHA is only meaningful when this checkout is the one that
# pushed the PR's head branch. When the PR number was given explicitly that
# association is unverified — a checkout sitting on any other branch pins the
# wrong commit, and every later verdict then describes the wrong push. So
# compare HEAD's upstream against the PR's head branch and refuse to guess on
# a mismatch. Detached HEAD, no upstream, or a cross-repository PR is
# inconclusive: proceed, and the mismatch verdicts carry the provenance hint
# instead.
confirm_defaulted_sha() {
  _info=$(ghq pr view "$PR" --json headRefName,isCrossRepository \
    --jq '[.headRefName, (.isCrossRepository | tostring)] | @tsv') || return 0
  _branch=${_info%%"$(printf '\t')"*}
  _cross=${_info##*"$(printf '\t')"}
  [ "$_cross" = "true" ] && return 0
  _upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || return 0
  [ "$_upstream" = "$REMOTE/$_branch" ] && return 0
  say "refusing to default the expected SHA: this checkout tracks $_upstream, but PR #$PR's head branch is $_branch"
  finish 1 setup-error "pass --sha explicitly: the commit you pushed ($(printf '%.8s' "$EXPECTED_SHA") if that really is this checkout's HEAD), or the PR's reported head — gh pr view $PR --json headRefOid --jq .headRefOid — to verify the PR as it stands"
}
[ "$PR_GIVEN" -eq 1 ] && [ "$SHA_DEFAULTED" -eq 1 ] && confirm_defaulted_sha

# Appended to verdicts that suggest the expected SHA itself may be wrong.
sha_hint() {
  [ "$SHA_DEFAULTED" -eq 1 ] \
    && printf ' (the expected SHA was defaulted from the local HEAD — if this is not the checkout you pushed from, re-run with --sha)'
  return 0
}

DEADLINE=$((SECONDS + TIMEOUT))

# --- snapshot: one API call per poll -> SNAP_HEAD, SNAP_STATE, -------------
# --- SNAP_MERGEABLE, SNAP_ROLLUP --------------------------------------------
# SNAP_ROLLUP is "name<TAB>result" lines; result is normalized so that
# anything unfinished reads PENDING and finished states keep their GraphQL
# names (SUCCESS, FAILURE, CANCELLED, ...). Handles both rollup node shapes
# (CheckRun and commit-status StatusContext). SNAP_MERGEABLE is GitHub's
# async merge-commit computation: MERGEABLE, CONFLICTING, or UNKNOWN (still
# computing — never act on UNKNOWN).
snapshot() {
  _snap=$(ghq pr view "$PR" --json headRefOid,state,mergeable,statusCheckRollup --jq '
    .headRefOid, .state, .mergeable,
    (.statusCheckRollup[]? |
      [ (.name // .context // "?"),
        (if .__typename == "CheckRun"
         then (if .status != "COMPLETED" then "PENDING" else (.conclusion // "PENDING") end)
         else (if .state == "EXPECTED" then "PENDING" else (.state // "PENDING") end)
         end) ] | @tsv)') || return 1
  SNAP_HEAD=$(printf '%s\n' "$_snap" | sed -n 1p)
  SNAP_STATE=$(printf '%s\n' "$_snap" | sed -n 2p)
  SNAP_MERGEABLE=$(printf '%s\n' "$_snap" | sed -n 3p)
  SNAP_ROLLUP=$(printf '%s\n' "$_snap" | sed -n '4,$p' | sort -u)
}

classify() {
  NAMES=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' 'NF {print $1}')
  PENDING_LIST=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' 'NF && $2 == "PENDING" {print $1}')
  FAILED_LIST=$(printf '%s\n' "$SNAP_ROLLUP" | awk -F'\t' \
    'NF && $2 != "PENDING" && $2 != "SUCCESS" && $2 != "SKIPPED" && $2 != "NEUTRAL" {print $1 " (" $2 ")"}')
}

# Required checks not yet present in the rollup at all.
missing_required() {
  [ -z "$REQUIRED" ] && return 0
  while IFS= read -r _ctx; do
    [ -z "$_ctx" ] && continue
    printf '%s\n' "$NAMES" | grep -Fxq -- "$_ctx" || printf '%s\n' "$_ctx"
  done <<EOF
$REQUIRED
EOF
}

# Failures that gate the verdict: required-only when a required list exists,
# otherwise every failure.
gating_failures() {
  if [ -z "$REQUIRED" ]; then printf '%s\n' "$FAILED_LIST" | grep . || true; return 0; fi
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _name=${_line% (*}
    printf '%s\n' "$REQUIRED" | grep -Fxq -- "$_name" && printf '%s\n' "$_line"
  done <<EOF
$FAILED_LIST
EOF
  return 0
}

deadline_check() { # <what we're still waiting for>
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    finish 3 pending "deadline (${TIMEOUT}s) reached — $1 — re-run to keep waiting"
  fi
}

# While checks are failing to register, a CONFLICTING PR is the likely cause:
# pull_request-triggered workflows run against the merge commit, and a PR that
# conflicts with its base has none, so those checks never start — the barrier
# would otherwise spin until the deadline. Grace period covers push-triggered
# checks that register slowly on a PR that happens to also be conflicting; a
# flip back to MERGEABLE/UNKNOWN (a base update mid-wait) resets it.
CONFLICT_GRACE=45
CONFLICT_SINCE=""
conflict_check() {
  if [ "$SNAP_MERGEABLE" = "CONFLICTING" ]; then
    if [ -z "$CONFLICT_SINCE" ]; then
      CONFLICT_SINCE=$SECONDS
      progress "PR #$PR is CONFLICTING with its base — pull_request-triggered checks cannot start without a merge commit"
    elif [ $((SECONDS - CONFLICT_SINCE)) -ge "$CONFLICT_GRACE" ]; then
      finish 7 conflicting "no checks registering and PR #$PR conflicts with its base — its merge commit cannot be built, so pull_request-triggered workflows will never run; rebase or merge the base branch into the head branch, push, and re-run"
    fi
  else
    CONFLICT_SINCE=""
  fi
}

# One unpiped watch, bounded by the overall deadline. Its exit code is
# intentionally ignored; the caller re-verifies the rollup afterwards.
bounded_watch() {
  gh pr checks "$PR" --watch --fail-fast >/dev/null 2>&1 &
  _wpid=$!
  while kill -0 "$_wpid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
      kill "$_wpid" 2>/dev/null
      break
    fi
    sleep 10
  done
  wait "$_wpid" 2>/dev/null
  return 0
}

report_table() {
  [ -z "$SNAP_ROLLUP" ] && return 0
  say "check status:"
  printf '%s\n' "$SNAP_ROLLUP" | while IFS="$(printf '\t')" read -r _n _r; do
    [ -z "$_n" ] && continue
    case "$_r" in
      SUCCESS|SKIPPED|NEUTRAL) _mark="ok " ;;
      PENDING) _mark=".. " ;;
      *) _mark="XX " ;;
    esac
    _req=""
    if [ -n "$REQUIRED" ] && printf '%s\n' "$REQUIRED" | grep -Fxq -- "$_n"; then
      _req=" (required)"
    fi
    printf '  %s%s: %s%s\n' "$_mark" "$_n" "$_r" "$_req" >&2
  done
}

# Ask the git remote directly whether the expected SHA actually landed on the
# PR's head branch. Only consulted when the API-reported PR head disagrees
# with the expected SHA, to tell "push never landed" (fail fast, exit 4)
# apart from "API is lagging behind a real push" (keep waiting). Retries
# cover replica lag right after a successful push. Sets PUSH_CONFIRMED=1 when
# the remote has the SHA; inconclusive situations (fork PR, no local git repo,
# ls-remote failing) return without a verdict.
verify_remote_ref() {
  _info=$(ghq pr view "$PR" --json headRefName,isCrossRepository \
    --jq '[.headRefName, (.isCrossRepository | tostring)] | @tsv') || return 0
  _branch=${_info%%"$(printf '\t')"*}
  _cross=${_info##*"$(printf '\t')"}
  if [ "$_cross" = "true" ]; then
    progress "cross-repository PR — cannot verify the push via '$REMOTE'; relying on the API head"
    return 0
  fi
  git rev-parse --git-dir >/dev/null 2>&1 \
    || { progress "not inside a git repository — skipping direct remote verification"; return 0; }
  _remote_sha=""
  _tries=0
  while [ "$_tries" -lt 4 ]; do
    if _ls=$(git ls-remote "$REMOTE" "refs/heads/$_branch" 2>/dev/null); then
      _remote_sha=$(printf '%s\n' "$_ls" | awk 'NR == 1 {print $1}')
      if [ "$_remote_sha" = "$EXPECTED_SHA" ]; then
        PUSH_CONFIRMED=1
        progress "push confirmed on $REMOTE/$_branch — waiting for the API to catch up"
        return 0
      fi
    else
      progress "git ls-remote $REMOTE failed — skipping direct remote verification"
      return 0
    fi
    _tries=$((_tries + 1))
    sleep 5
  done
  if [ -z "$_remote_sha" ]; then
    finish 4 push-missing "branch '$_branch' does not exist on $REMOTE — the push never landed (a bare 'git push' with mismatched local/remote branch names silently no-ops; push with an explicit refspec: git push $REMOTE HEAD:$_branch)"
  fi
  finish 4 push-missing "$REMOTE/$_branch is at $(printf '%.8s' "$_remote_sha"), expected $(printf '%.8s' "$EXPECTED_SHA") — the push didn't land (push with an explicit refspec: git push $REMOTE HEAD:$_branch; if a newer commit was pushed intentionally, re-run with --sha)$(sha_hint)"
}

# --- stage 1: confirm the PR is open and its head is the expected SHA -------
progress "watching PR #$PR for head $(printf '%.8s' "$EXPECTED_SHA") (timeout ${TIMEOUT}s)"
HEAD_BARRIER=$((SECONDS + 180))
PUSH_CONFIRMED=0
GIT_CHECKED=0
while :; do
  snapshot || finish 1 setup-error "could not query PR #$PR"
  case "$SNAP_STATE" in
    OPEN) ;;
    MERGED) finish 6 already-merged "PR #$PR is already merged" ;;
    *) finish 6 not-open "PR #$PR state is $SNAP_STATE" ;;
  esac
  [ "$SNAP_HEAD" = "$EXPECTED_SHA" ] && break
  if [ "$GIT_CHECKED" -eq 0 ]; then
    GIT_CHECKED=1
    verify_remote_ref
  fi
  if [ "$SECONDS" -ge "$HEAD_BARRIER" ]; then
    if [ "$PUSH_CONFIRMED" -eq 1 ]; then
      finish 4 head-mismatch "the push landed on $REMOTE but the PR head is still $(printf '%.8s' "$SNAP_HEAD") — the API never caught up; re-run to keep waiting"
    fi
    finish 4 head-mismatch "PR head is $(printf '%.8s' "$SNAP_HEAD"), expected $(printf '%.8s' "$EXPECTED_SHA") — did the push land? (a bare 'git push' with mismatched local/remote branch names silently no-ops; push with an explicit refspec and re-run)$(sha_hint)"
  fi
  progress "PR head is $(printf '%.8s' "$SNAP_HEAD"), waiting for the push to land…"
  sleep 5
done
progress "head SHA confirmed on PR #$PR"

# --- stage 2: discover the base branch's required checks --------------------
BASE=$(ghq pr view "$PR" --json baseRefName --jq .baseRefName) || BASE=""
REQUIRED=""
if [ -n "$BASE" ]; then
  # Capture each call and discard its output on failure — gh api prints the
  # error body (JSON) to stdout on a 404, which would pollute the list.
  RULESET_REQ=$(gh api "repos/{owner}/{repo}/rules/branches/$BASE" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null) \
    || RULESET_REQ=""
  LEGACY_REQ=$(gh api "repos/{owner}/{repo}/branches/$BASE/protection/required_status_checks" \
    --jq '.checks[]?.context // empty' 2>/dev/null) \
    || LEGACY_REQ=""
  REQUIRED=$(printf '%s\n%s\n' "$RULESET_REQ" "$LEGACY_REQ" | sort -u | grep . || true)
fi
if [ -n "$REQUIRED" ]; then
  progress "required checks on $BASE: $(oneline "$REQUIRED")"
else
  progress "no required-check list found for $BASE — gating on ALL reported checks"
fi

# --- stage 3+4: barrier, watch, verify — loop until a definitive verdict ----
PREV_COUNT=-1
while :; do
  snapshot || finish 1 setup-error "could not query PR #$PR"
  case "$SNAP_STATE" in
    OPEN) ;;
    MERGED) finish 6 already-merged "PR #$PR was merged while waiting" ;;
    *) finish 6 not-open "PR #$PR state became $SNAP_STATE" ;;
  esac
  if [ "$SNAP_HEAD" != "$EXPECTED_SHA" ]; then
    finish 5 head-moved "PR head moved to $(printf '%.8s' "$SNAP_HEAD") (a new push happened) — re-run against the new head"
  fi
  classify

  # Barrier: don't trust anything until the expected checks are registered.
  if [ -n "$REQUIRED" ]; then
    MISSING=$(missing_required)
    if [ -n "$MISSING" ]; then
      conflict_check
      deadline_check "required check(s) never registered: $(oneline "$MISSING")"
      progress "waiting for required check(s) to register: $(oneline "$MISSING")"
      sleep 10
      continue
    fi
  else
    COUNT=$(printf '%s\n' "$SNAP_ROLLUP" | grep -c .)
    if [ "$COUNT" -eq 0 ] || [ "$COUNT" != "$PREV_COUNT" ]; then
      conflict_check
      deadline_check "checks still registering ($COUNT reported)"
      progress "waiting for the reported check set to settle ($COUNT so far)…"
      PREV_COUNT=$COUNT
      sleep 15
      continue
    fi
  fi
  CONFLICT_SINCE=""

  # A required check already failed: no point waiting for the rest.
  GATING=$(gating_failures)
  if [ -n "$GATING" ]; then
    report_table
    finish 2 failed "not green — failing: $(oneline "$GATING")"
  fi

  if [ -n "$PENDING_LIST" ]; then
    progress "$(printf '%s\n' "$PENDING_LIST" | grep -c .) check(s) pending (elapsed ${SECONDS}s) — watching…"
    bounded_watch
    deadline_check "still pending: $(oneline "$PENDING_LIST")"
    sleep 5
    continue
  fi

  # Nothing pending, everything registered: final verdict.
  report_table
  if [ -n "$FAILED_LIST" ]; then
    say "note: non-required check(s) not green: $(oneline "$FAILED_LIST")"
  fi
  if [ "$SNAP_MERGEABLE" = "CONFLICTING" ]; then
    say "note: checks are green but the PR is CONFLICTING with its base — resolve conflicts before merging"
  fi
  finish 0 green "verified green on $(printf '%.8s' "$EXPECTED_SHA")"
done
