#!/usr/bin/env bash
# Runs a command while holding this checkout's build lock, so no two
# xcodebuild runs ever share the checkout's build arena. A run that finds the
# lock held prints one line to stderr and waits for it.
#
#     Tools/checkout-lock.sh <command> [<arg>...]
#
# Exits with the command's status, or dies by the signal that ended it.
#
# The lock is `xcodebuild.lock` in this checkout's own git dir (a linked
# worktree's lies under .git/worktrees/<name>/), outside the working tree, so
# `git clean` cannot unlink it from under a holder, and separate checkouts
# never wait on each other. It is not reentrant: a locked command that runs
# another locked command waits on itself forever.
#
# This script's process holds the lock and the command runs as its child:
# - The lock descriptor is close-on-exec, so neither the command nor anything
#   it leaves running holds it.
# - SIGTERM and SIGHUP are passed on to the command, and the lock is held
#   until the command exits.
# - SIGINT and SIGQUIT are left to the terminal, which signals the whole
#   foreground group.
# - The holder ending by SIGKILL alone releases the lock while the command
#   runs on. /usr/bin/lockf has the same gap for every signal: it releases
#   on SIGTERM and SIGHUP and leaves its child running.

set -uo pipefail

[ $# -gt 0 ] || { echo 'usage: Tools/checkout-lock.sh <command> [<arg>...]' >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock=$(git -C "$ROOT" rev-parse --path-format=absolute --git-path xcodebuild.lock) || {
    echo "checkout-lock.sh: $ROOT is not a git checkout; cannot place its build lock" >&2
    exit 2
}

exec perl -e '
    use strict;
    use warnings;
    use Fcntl qw(:flock O_RDWR O_CREAT);
    use POSIX qw(:sys_wait_h :signal_h);

    my ($lock, @command) = @ARGV;

    # Perl opens every descriptor above $^F (2) close-on-exec.
    sysopen(my $fh, $lock, O_RDWR | O_CREAT, 0644)
        or die "checkout-lock.sh: cannot open $lock: $!\n";
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        $!{EWOULDBLOCK} or die "checkout-lock.sh: cannot lock $lock: $!\n";
        print STDERR "checkout-lock.sh: waiting for another xcodebuild in this checkout to finish ($lock)\n";
        flock($fh, LOCK_EX) or die "checkout-lock.sh: cannot lock $lock: $!\n";
    }

    # Blocked across the fork, so a signal cannot arrive before $pid names
    # the child it is to be passed to.
    my $forwarded = POSIX::SigSet->new(SIGTERM, SIGHUP);
    my $previous = POSIX::SigSet->new;
    sigprocmask(SIG_BLOCK, $forwarded, $previous) or die "checkout-lock.sh: sigprocmask: $!\n";

    my $pid = fork;
    defined $pid or die "checkout-lock.sh: fork: $!\n";
    if ($pid == 0) {
        sigprocmask(SIG_SETMASK, $previous);
        { no warnings "exec"; exec { $command[0] } @command; }
        print STDERR "checkout-lock.sh: cannot run $command[0]: $!\n";
        POSIX::_exit(127);
    }

    # Caught rather than ignored, so the child execs with the default action.
    $SIG{$_} = sub { kill $_[0], $pid } for qw(TERM HUP);
    $SIG{$_} = sub { } for qw(INT QUIT);
    sigprocmask(SIG_SETMASK, $previous);

    my $status;
    while (1) {
        my $reaped = waitpid($pid, 0);
        if ($reaped == $pid) { $status = $?; last }
        $!{EINTR} or die "checkout-lock.sh: waitpid: $!\n";
    }

    # An explicit unlock releases the lock even while a child being spawned
    # still references the descriptor
    # (docs/research/2026-10-07-a-spawning-child-holds-a-cloexec-flock-until-exec.md).
    flock($fh, LOCK_UN);
    close $fh;

    if (WIFSIGNALED($status)) {
        my $signal = WTERMSIG($status);
        $SIG{$_} = "DEFAULT" for qw(TERM HUP INT QUIT);
        kill $signal, $$;
        sigprocmask(SIG_UNBLOCK, POSIX::SigSet->new($signal));
        exit 128 + $signal;
    }
    exit WEXITSTATUS($status);
' "$lock" "$@"
