#!/usr/bin/env bash
# Runs a command holding the build lock of the checkout this script is in, so
# no two builds share the checkout's DerivedData/: a second run prints one
# line and waits. Every xcodebuild of the checkout runs under it, through
# Tools/xcodebuild.sh or `make dead-code`.
#
#     Tools/build-lock.sh <command> [<arg>...]
#
# The lock is an flock on xcodebuild.lock in the checkout's git dir, held by
# this script's process until the command exits. The command gets no
# descriptor on it, so nothing it leaves running — xcodebuild's build service —
# holds it, and a SIGTERM or SIGHUP here takes effect only once the command has
# exited. A command run under the lock that asks for it again waits on itself.

set -uo pipefail

[ $# -gt 0 ] || { echo 'usage: Tools/build-lock.sh <command> [<arg>...]' >&2; exit 2; }
lock=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-path xcodebuild.lock) || exit 1
exec 9>>"$lock" || exit 1
perl -MFcntl=:flock -e '
    open(my $fh, ">&=", 9) or die "build-lock.sh: $!\n";
    exit 0 if flock($fh, LOCK_EX | LOCK_NB);
    print STDERR "build-lock.sh: waiting for another build in this checkout to finish\n";
    flock($fh, LOCK_EX) or die "build-lock.sh: cannot lock $ARGV[0]: $!\n";
' "$lock" || exit 1
trap 'exit 143' TERM
trap 'exit 129' HUP
"$@" 9>&-
