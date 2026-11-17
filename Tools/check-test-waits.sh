#!/usr/bin/env bash
# A test that sleeps on the real clock bets that the work it waits for fits
# inside the span, and a starved CI runner loses the bet: a positive wait
# fails, and a sleep-then-assert-nothing check passes before the thing it
# rules out could have happened. A test wait ends on the event it waits for,
# and fails by name at its `Backstop` when the event never comes, through the
# seams in KernovaPortableTestSupport (`Backstop`, `AsyncGate`,
# `BlockingCall`, `ChildProcess`) and KernovaCoreTestSupport (`waitForChange`).
# A wait outside
# them parks until the test plan's allowance stops the process, naming nothing
# and losing every result still running in it.
#
# Scope is every tracked Swift file with a directory component ending in
# `Tests`: a test target, its `Support/` folder included. A test-support module
# (`…TestSupport/`) is not scanned. A window a test genuinely needs — a
# backstop, a wait helper's own clock, a double that parks for good — is a
# named helper there, its window stated in its `///`, so every suite reaches it
# through one spelling. Given file arguments, relative ones resolved against
# the caller's working directory, it scans those instead; its fixture test
# drives it that way.
#
# A raw real-clock sleep is a call to `Task.sleep`, `Thread.sleep`,
# `asyncAfter`, or a bare or `Darwin.`-qualified `sleep`, `usleep` or
# `nanosleep` — or a `.sleep` on a real clock constructed in the same
# expression: `MonotonicEngineClock()`, `ContinuousEngineClock()`,
# `ContinuousClock()`, `SuspendingClock()`, `ContinuousClock.continuous`,
# `SuspendingClock.suspending`. A bare call in a file declaring a `func` of the
# same name resolves to that function and is not one.
#
# A sleep through a named clock, `clock.sleep(for:)`, is not matched: its type
# is not on the line, and an injected test clock (`TestEngineClock`,
# `GatedEngineClock`) reaches every test as a name, so matching names would
# refuse the sleeps that take no real time. A real clock bound to a name first
# passes unmatched.
#
# A wait with no deadline is the second finding, in the shapes a test writes
# only to wait: a raw continuation (`withCheckedContinuation`,
# `withCheckedThrowingContinuation`, `withUnsafeContinuation`,
# `withUnsafeThrowingContinuation`) parks through `Backstop.park`; a blocking
# `.wait()` with no arguments — a semaphore's, a group's, a condition's — or
# one whose `timeout:` is `.distantFuture` blocks through `Backstop.wait(for:)`;
# `Task.detached`, which a test reaches for to run a blocking call it then
# awaits, runs it through `offCooperativePool` or `BlockingCall`; and a child
# process's `waitUntilExit()`, `readDataToEndOfFile()` or `readToEnd()` waits
# through `ChildProcess`. A `.wait()` an `await` precedes is another type's
# async wait and is not matched.
#
# A number in a wait's `timeout:` argument is the third finding: a wait that
# expects success takes the `testWaitBackstop` default, and a smaller deadline
# is a window racing the work. A wait is a call whose name starts with `wait`,
# or `fulfillment` or `Backstop`; a `timeout:` passed to any other call
# configures the subject and is not matched. When the deadline is what the test
# asserts, `// deadline-under-test - <reason>` on the `timeout:` line or the
# line above it exempts that argument; a marker without a reason exempts
# nothing. No marker exempts a sleep or a wait with no deadline.
#
# String literals and comments are blanked before matching, so prose may name
# what it forbids. Reports every finding before failing, and fails on a file
# it could not read.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    cd "$(git rev-parse --show-toplevel)" || exit 1
    files=()
    while IFS= read -r file; do
        files+=("$file")
    done < <(git ls-files '*.swift' | grep -E '(^|/)[^/]*Tests/')
fi

findings=$(perl -e '
    use strict;
    use warnings;

    # As in check-config-decoding.sh: each literal or comment in source
    # order, raw and multi-line strings before plain ones.
    my $blankable = qr{
        (?(DEFINE)
            (?<block> /\* (?: [^/*]++ | /(?!\*) | \*(?!/) | (?&block) )*+ \*/ )
        )
        (?<string>
            (?<hashes>\#++) " (?: "" )? .*? " (?: "" )? \k<hashes>
          | """ .*? """
          | " (?: \\. | [^"\\\n] )* "
        )
      | (?<comment> //[^\n]* | (?&block) )
    }xs;

    my $real_clock = qr{
        \b (?: MonotonicEngineClock | ContinuousEngineClock | ContinuousClock | SuspendingClock )
            \s* \( \s* \)
      | \b ContinuousClock \s* \. \s* continuous \b
      | \b SuspendingClock \s* \. \s* suspending \b
    }x;

    my $sleep = qr{
        (?<![\w.]) (?<qualified> Darwin \s* \. \s* )? (?<bare> sleep | usleep | nanosleep ) \s* \(
      | \b Task \s* (?: < [^<>]* > )? \s* \. \s* sleep \s* \(
      | \b Thread \s* \. \s* sleep \s* \(
      | \. \s* asyncAfter \s* \(
      | $real_clock \s* \. \s* sleep \s* \(
    }x;

    my $unbounded = qr{
        \b (?<continuation> with (?: Checked | Unsafe ) (?: Throwing )? Continuation ) \b
      | \b (?<detached> Task \s* \. \s* detached ) \b
      | (?<blocking> \. \s* wait \s* \( \s* \) )
      | (?<forever> \. \s* wait \s* \( \s* (?: wall )? [tT]imeout \s* : \s* (?: DispatchTime \s* | DispatchWallTime \s* )? \. \s* distantFuture \b )
      | (?<child> \. \s* (?: waitUntilExit | readDataToEndOfFile | readToEnd ) \s* \( \s* \) )
    }x;

    my $marker = qr{//\s*deadline-under-test\s+-\s+\S};

    sub line_at { my ($code, $offset) = @_; return (substr($code, 0, $offset) =~ tr/\n//) + 1 }

    # Where the receiver of the member call whose `.` is at $dot starts: back
    # over names, `.`, `?`, `!`, balanced subscripts and calls, and a line
    # break that continues a chain.
    sub receiver_start {
        my ($code, $dot) = @_;
        my $i = $dot - 1;
        while ($i >= 0) {
            my $c = substr($code, $i, 1);
            if ($c =~ /[\w?!.]/) { $i--; next }
            if ($c =~ /[\])]/) {
                my $depth = 0;
                for (; $i >= 0; $i--) {
                    my $d = substr($code, $i, 1);
                    if ($d =~ /[\])]/) { $depth++ }
                    elsif ($d =~ /[\[(]/) { $depth--; last if $depth == 0 }
                }
                $i--;
                next;
            }
            if ($c =~ /\s/ && substr($code, $i + 1, 1) eq ".") {
                $i-- while $i >= 0 && substr($code, $i, 1) =~ /\s/;
                next;
            }
            last;
        }
        return $i + 1;
    }

    # The argument list opening at $open, split at its top-level commas:
    # each argument with its offset, or nothing when the list never closes.
    sub arguments {
        my ($code, $open) = @_;
        my ($depth, $start, @args) = (0, $open + 1);
        for (my $i = $open; $i < length $code; $i++) {
            my $c = substr($code, $i, 1);
            if ($c =~ /[(\[{]/) { $depth++ }
            elsif ($c =~ /[)\]}]/) {
                $depth--;
                if ($depth == 0) { push @args, [$start, substr($code, $start, $i - $start)]; return @args }
            }
            elsif ($c eq "," && $depth == 1) { push @args, [$start, substr($code, $start, $i - $start)]; $start = $i + 1 }
        }
        return ();
    }

    my $failed = 0;
    for my $arg (@ARGV) {
        my $code;
        if (open(my $fh, "<", $arg)) {
            local $/;
            $code = <$fh>;
            close $fh;
        }
        unless (defined $code) {
            print STDERR "check-test-waits: cannot read $arg: $!\n";
            $failed = 1;
            next;
        }
        my @raw = split /\n/, $code, -1;
        $code =~ s{$blankable}{
            my $kept = $&;
            $kept =~ tr/\n//cd;
            (defined $+{string} ? q{""} : q{ }) . $kept
        }ge;

        my %declared = map { $_ => 1 } $code =~ /\bfunc\s+(\w+)/g;
        my %found;

        while ($code =~ m{$sleep}g) {
            my $start = $-[0];
            next if defined $+{bare} && !defined $+{qualified} && $declared{$+{bare}};
            $found{line_at($code, $start)} //= "a raw real-clock sleep; wait on the event through a test-support seam, or make a deliberate window a named helper there";
        }

        while ($code =~ m{$unbounded}g) {
            my $start = $-[0];
            if (defined $+{continuation}) {
                $found{line_at($code, $start)} //= "a raw continuation, which parks with no deadline; park through Backstop.park, or make a double that parks for good a named helper in a test-support module";
            } elsif (defined $+{detached}) {
                $found{line_at($code, $start)} //= "a detached task, whose value is awaited with no deadline; run a blocking call through offCooperativePool or BlockingCall";
            } elsif (defined $+{forever}) {
                $found{line_at($code, $start)} //= "a blocking wait whose deadline never comes; block through Backstop.wait(for:)";
            } elsif (defined $+{child}) {
                $found{line_at($code, $start)} //= "a wait on a child process with no deadline; run it through ChildProcess";
            } else {
                next if substr($code, 0, receiver_start($code, $start)) =~ /\bawait\s*\z/;
                $found{line_at($code, $start)} //= "a blocking wait with no deadline; block through Backstop.wait(for:)";
            }
        }

        while ($code =~ m{\b(\w+)\s*\(}g) {
            my ($callee, $open) = ($1, $+[0] - 1);
            next unless $callee =~ /^(?:wait|fulfillment$|Backstop$)/;
            for my $argument (arguments($code, $open)) {
                my ($offset, $text) = @$argument;
                next unless $text =~ /^(\s*)timeout\s*:(.*)$/s;
                my ($lead, $value) = ($1, $2);
                next unless $value =~ /(?<![\w.])\.?\d/;
                my $line = line_at($code, $offset + length $lead);
                next if $raw[$line - 1] =~ $marker || ($line > 1 && $raw[$line - 2] =~ $marker);
                $found{$line} //= "a numeric deadline on a wait; one expecting success takes the testWaitBackstop default, and a deadline the test asserts carries a deadline-under-test marker";
            }
        }

        print "$arg:$_ — $found{$_}\n" for sort { $a <=> $b } keys %found;
    }
    exit($failed ? 2 : 0);
' -- "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-test-waits: $line" >&2
    done
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-test-waits: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

[ -z "$findings" ] || exit 1

pass "test waits: no test sleeps on the real clock, waits with no deadline, or races a wait against a numeric deadline"
