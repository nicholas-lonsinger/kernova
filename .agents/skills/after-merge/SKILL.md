---
name: after-merge
description: >-
  Fast-forward the local default branch onto the remote after a pull request
  merges, and report in one line whether the calling worktree's content is on
  it. Use right after
  confirming a squash merge landed, and whenever the local default branch is
  stale — especially from inside a git worktree, where the branch is checked
  out in another directory and the worktree-isolation guard blocks a direct
  `git -C` against it.
argument-hint: "[--remote <name>] [--discard <path>]..."
---

Run `.agents/skills/after-merge/after-merge.sh $ARGUMENTS`; its `--help` defines every flag, verdict and worktree token, and exit code.

`worktree=merged` means this worktree's content is on the remote default branch, so choosing Remove at Claude Code's exit prompt discards nothing; `unmerged` before the PR merges is expected.

A `dirty` verdict naming `Kernova.xcodeproj/project.pbxproj` is usually Xcode rewriting the project file while it has the project open (reordered entries, dropped quotes), but the script cannot tell that churn from an edit the user meant to keep — the `--discard` is theirs to call.
