---
name: wait-github-ci
description: >-
  Block until a pull request's CI is verifiably green before merging or
  building on it. Use after pushing to a PR branch — it confirms the push
  actually landed on the remote, waits for the checks to register and finish,
  and renders a trustworthy verdict, where a bare `gh pr checks --watch` can
  race a fresh push and return a false green.
argument-hint: "[<pr-number>] [--sha <sha>] [--timeout <seconds>]"
---

# Wait for a PR's CI

A watch started right after a push races three things: the push itself (a
bare `git push` with mismatched local/remote branch names silently no-ops),
the API's view of the PR head, and check registration (zero checks reported
reads as success). The script owns the whole choreography — pin the expected
SHA, verify the push landed via `git ls-remote`, barrier on the required
checks registering, watch, then verify the final rollup directly. While
checks fail to register it also watches the PR's mergeable state: a PR that
conflicts with its base has no merge commit, so pull_request-triggered
workflows can never start — that returns exit 7 promptly instead of
spinning to the deadline.

## Run it

After pushing, from inside the repository:

```bash
.agents/skills/wait-github-ci/wait-github-ci.sh <pr-number>
```

The PR number defaults to the current branch's PR, and the expected head SHA
to `git rev-parse HEAD` — right only in the checkout the push came from. From
anywhere else (another worktree, a session that never pushed), pass `--sha`:
the SHA you pushed, or the PR's reported head — `gh pr view <n> --json
headRefOid --jq .headRefOid` — to verify the PR as it stands (that forgoes
the push-landed proof, since the expectation then comes from the same API).
With an explicit PR number, a checkout whose upstream is not the PR's head
branch is refused (exit 1) rather than silently pinning the wrong commit.
`--timeout <seconds>` bounds one invocation (default 3600), `--repo
<owner/repo>` and `--remote <name>` cover non-default setups.

## How to wait

One invocation is bounded by `--timeout`, and exit 3 means nothing is wrong —
call again against the same SHA to keep waiting. So the wait splits across
calls however your situation requires; pick by what you are allowed to do,
not by what kind of session you are:

- **You may end the turn and be re-invoked** — run it as a **background**
  Bash command with the default deadline. The exit re-invokes you with the
  exit code and output; do not poll or sleep meanwhile.
- **You must return a result within this turn** (your instructions forbid
  ending it while work is pending) — run it in the **foreground** with
  `--timeout` under the Bash call's own timeout, and re-run it on exit 3.

## Reading the result

Progress goes to stderr; the last stdout line is machine-readable
(`wait-github-ci: verdict=... pr=... sha=...`). Branch on the exit code:

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

Merge only on exit 0. Do not substitute a hand-rolled `gh pr checks --watch`
or a sleep loop: the watch's exit code alone is not a verdict (it is 0 for
"no checks registered yet" and for cancelled runs), and improvising the
choreography reintroduces exactly the races the script exists to close.
