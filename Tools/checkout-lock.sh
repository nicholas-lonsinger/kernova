#!/usr/bin/env bash
# Runs a command while holding a checkout's build lock, so no two xcodebuild
# runs ever share the checkout's build arena. Every process that runs
# xcodebuild against a checkout runs it through here. A run that finds the
# lock held prints one line to stderr and waits for it.
#
#     Tools/checkout-lock.sh [-C <checkout>] <command> [<arg>...]
#
# <checkout> defaults to the one holding this script. Exits with the
# command's status, or dies by the signal that ended it.
#
# The lock is `xcodebuild.lock` in the checkout's own git dir (a linked
# worktree's lies under .git/worktrees/<name>/), outside the working tree, so
# `git clean` cannot unlink it from under a holder, and separate checkouts
# never wait on each other.
#
# A descendant of the holder runs its command at once rather than waiting on
# its own ancestor: the holder names itself in KERNOVA_CHECKOUT_LOCKS, and an
# entry counts only while its pid is an ancestor of the caller, so a copied or
# inherited value cannot let an unrelated process past the lock.
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

usage() { echo 'usage: Tools/checkout-lock.sh [-C <checkout>] <command> [<arg>...]' >&2; exit 2; }

checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = -C ]; then
    [ $# -ge 2 ] || usage
    checkout=$2
    shift 2
fi
[ $# -gt 0 ] || usage

lock=$(git -C "$checkout" rev-parse --path-format=absolute --git-path xcodebuild.lock) || {
    echo "checkout-lock.sh: $checkout is not a git checkout; cannot place its build lock" >&2
    exit 2
}

# held_by_ancestor — an entry in KERNOVA_CHECKOUT_LOCKS names this lock and a
# pid on this process's parent chain.
held_by_ancestor() {
    local holder path pid
    while IFS=$'\t' read -r holder path; do
        [ "$path" = "$lock" ] || continue
        pid=$$
        while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
            [ "$pid" = "$holder" ] && return 0
            pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
        done
    done <<<"${KERNOVA_CHECKOUT_LOCKS:-}"
    return 1
}
if held_by_ancestor; then
    exec "$@"
fi

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

    $ENV{KERNOVA_CHECKOUT_LOCKS} = ($ENV{KERNOVA_CHECKOUT_LOCKS} // "") . "$$\t$lock\n";

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

    # Set after the fork, so the command starts with the dispositions this
    # script started with; the holder outlives the command whatever it gets.
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
