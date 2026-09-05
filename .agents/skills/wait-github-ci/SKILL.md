---
name: wait-github-ci
description: >-
  Block until a pull request's CI is verifiably green before merging or
  building on it. Use after pushing to a PR branch — it confirms the push
  actually landed on the remote, waits for the checks to register and finish,
  and returns a trustworthy verdict naming any failing checks, where a bare
  `gh pr checks --watch` can race a fresh push and return a false green. It
  runs in its own subagent and returns when CI has a verdict.
argument-hint: "[<pr-number>] [--sha <sha>]"
context: fork
background: true
agent: skill-runner
---

# Wait for a PR's CI

A watch started right after a push races three things: the push itself (a
bare `git push` with mismatched local/remote branch names silently no-ops),
the API's view of the PR head, and check registration (zero checks reported
reads as success). The script owns the whole choreography — pin the expected
SHA, verify the push landed via `git ls-remote`, barrier on the required
checks registering, watch, then verify the final rollup directly — and
reports a PR that conflicts with its base promptly instead of spinning to
the deadline.

## Run it

Arguments: $ARGUMENTS

From the repository root, in the foreground, with the shell call's timeout at
its maximum and the script's own deadline just under it:

```bash
.agents/skills/wait-github-ci/wait-github-ci.sh --timeout 540 $ARGUMENTS
```

Run the same command again on exit 3 (deadline expired, checks still
pending) and after a shell-call timeout, until it exits with any other code:
one invocation is bounded by `--timeout`, and re-running against the same
SHA is safe. Never substitute `gh pr checks --watch` or a sleep loop.

The PR number defaults to the current branch's PR, and the expected head SHA
to `git rev-parse HEAD` — right only in the checkout the push came from. From
anywhere else pass `--sha`: the SHA that was pushed, or the PR's reported
head (`gh pr view <n> --json headRefOid --jq .headRefOid`) to verify the PR
as it stands. With an explicit PR number, a checkout whose upstream is not
the PR's head branch is refused (exit 1) rather than silently pinning the
wrong commit.

## Reading the result

Progress goes to stderr; the last stdout line is machine-readable
(`wait-github-ci: verdict=... pr=... sha=...`). The exit code is the verdict:

| Exit | Meaning | Next action |
|---|---|---|
| 0 | Verified green on the expected SHA | Safe to merge / proceed |
| 1 | Usage or environment error | Fix the invocation |
| 2 | A gating check failed, was cancelled, or timed out | `gh run view <run-id> --log-failed`, fix, push, re-run |
| 3 | Deadline expired, checks still pending | Re-run to keep waiting |
| 4 | The push never landed on the remote | Push with an explicit refspec (`git push origin HEAD:<branch>`), re-run |
| 5 | PR head moved mid-wait (a new push happened) | Re-run against the new head |
| 6 | PR is not open (merged or closed) | Stop — nothing to wait for |
| 7 | PR conflicts with its base — no merge commit, so pull_request-triggered checks can never register | Rebase or merge the base into the head branch, push, re-run |

## Report

Return, and nothing else: the final run's `check status:` table and any
`failing:` or `note:` lines from its stderr, its last stdout line verbatim,
the exit code, and the matching "Next action" from the table. Merge only on
exit 0.
