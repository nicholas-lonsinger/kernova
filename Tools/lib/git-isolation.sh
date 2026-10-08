# A git environment that reaches no repository but the ones a fixture builds.
# Sourced, never run:
#
#     . "$ROOT/Tools/lib/git-isolation.sh"
#     isolate_git "$tmp"
#
# git exports GIT_DIR and its companions to a hook's child processes, so a
# fixture run under `pre-push` inherits the pushing checkout's repository. With
# GIT_DIR set, `git init <dir>` re-initializes GIT_DIR instead of <dir>, and
# for a linked worktree's gitdir it guesses bare and writes `core.bare = true`
# into the shared config.

# shellcheck shell=bash

# isolate_git <dir> — clear every variable git reads to locate a repository
# (`git rev-parse --local-env-vars` is git's own list of them), and pin the
# home directory, global and system config, and commit identity, so git reads
# nothing from this machine or the caller. <dir> is a scratch directory the
# caller owns; the home directory is made under it.
isolate_git() {
    # shellcheck disable=SC2046 # one variable name per word
    unset $(git rev-parse --local-env-vars)
    export HOME="$1/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    mkdir -p "$HOME"
}
