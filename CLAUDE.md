@AGENTS.md

## Worktree sessions

`ExitWorktree(remove)` deletes the `worktree-<name>` branch `EnterWorktree` created, by that name (observed 2026-09-17: a renamed scratch branch survives the removal), so leave the scratch branch named as-is and put the PR head name AGENTS.md prescribes on the remote alone: `git push -u origin HEAD:<type>/<short-description>`.

Claude Code's exit-time cleanup prompts before removing a worktree with new commits ([Worktrees](https://code.claude.com/docs/en/worktrees.md), "Clean up worktrees"), and it counts them from the commit the worktree was created from, so a squash-merged worktree always prompts (observed 2026-10-05). Once the PR reports `MERGED`, update the local default branch and confirm this worktree's content is on it; Remove at the exit prompt then discards nothing.
