@AGENTS.md

## Worktree sessions

`ExitWorktree(remove)` deletes the `worktree-<name>` branch `EnterWorktree` created, by that name (observed 2026-09-17: a renamed scratch branch survives the removal), so leave the scratch branch named as-is and put the PR head name AGENTS.md prescribes on the remote alone: `git push -u origin HEAD:<type>/<short-description>`.

Claude Code treats a worktree's branch as merged only when every commit on it is already on the default branch ([Worktrees](https://code.claude.com/docs/en/worktrees.md), "Clean up worktrees" and "Reuse a worktree name"), which a squash merge defeats; once the PR reports `MERGED`, `git fetch origin main && git reset --hard origin/main` in this worktree so exit-time cleanup can remove it.
