---
name: freshen-main
description: >-
  Fast-forward the local default branch onto the remote after a pull request
  merges, and report what happened in one line. Use right after confirming a
  squash merge landed, and whenever the local default branch is stale —
  especially from inside a git worktree, where the branch is checked out in
  another directory and the worktree-isolation guard blocks a direct `git -C`
  against it.
argument-hint: "[--remote <name>] [--discard <path>]..."
---

Run `.agents/skills/freshen-main/freshen-main.sh $ARGUMENTS`; its `--help` defines every flag, verdict token, and exit code.

A `dirty` verdict naming `Kernova.xcodeproj/project.pbxproj` is usually Xcode rewriting the project file while it has the project open (reordered entries, dropped quotes), but the script cannot tell that churn from an edit the user meant to keep — the `--discard` is theirs to call.
