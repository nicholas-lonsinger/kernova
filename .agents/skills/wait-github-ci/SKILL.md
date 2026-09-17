---
name: wait-github-ci
description: >-
  Block until a pull request's CI is verifiably green before merging or
  building on it. Use after pushing to a PR branch — it confirms the push
  actually landed on the remote, waits for the checks to register and finish,
  and returns a trustworthy verdict naming any failing checks, where a bare
  `gh pr checks --watch` can race a fresh push and return a false green. Run
  the script as a background shell call; the verdict arrives when it exits.
argument-hint: "[<pr-number>] [--sha <sha>] [--timeout <seconds>] [--verbose]"
---

Run `.agents/skills/wait-github-ci/wait-github-ci.sh $ARGUMENTS`; its `--help` defines every flag, verdict, and exit code.

From a subagent add `--timeout 240`: a subagent's prompt cache lives five minutes whatever the plan ([Claude Code: prompt caching](https://code.claude.com/docs/en/prompt-caching)), and the default deadline is sized to the main conversation's hour.
