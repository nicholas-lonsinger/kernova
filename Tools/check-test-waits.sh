#!/usr/bin/env bash
# A test that sleeps on the real clock bets that the work it waits for fits
# inside the span, and a starved CI runner loses the bet: a positive wait
# fails, and a sleep-then-assert-nothing check passes before the thing it
# rules out could have happened. A test wait ends on the event it waits for,
# through the seams in KernovaTestSupport (`AsyncGate`, `nextFrame`,
# `expectNoNewFrames`, `testWaitBackstop`) and KernovaCoreTestSupport
# (`waitForChange`).
#
# Scope is every tracked Swift file with a directory component ending in
# `Tests`: a test target, its `Support/` folder included. A test-support module
# (`…TestSupport/`) is not scanned. A window a test genuinely needs — a
# backstop, a wait helper's own clock — is a named helper there, its window
# stated in its `///`, so every suite reaches it through one spelling. Given
# file arguments, relative ones resolved against the caller's working
# directory, it scans those instead; its fixture test drives it that way.
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
# A number in a wait's `timeout:` argument is the other finding: a wait that
# expects success takes the `testWaitBackstop` default, and a smaller deadline
# is a window racing the work. A wait is a call whose name starts with `wait`,
# or `fulfillment`; a `timeout:` passed to any other call configures the
# subject and is not matched. When the deadline is what the test asserts,
# `// deadline-under-test - <reason>` on the `timeout:` line or the line above
# it exempts that argument; a marker without a reason exempts nothing. No
# marker exempts a sleep.
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

    my $marker = qr{//\s*deadline-under-test\s+-\s+\S};

    sub line_at { my ($code, $offset) = @_; return (substr($code, 0, $offset) =~ tr/\n//) + 1 }

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

        while ($code =~ m{\b(\w+)\s*\(}g) {
            my ($callee, $open) = ($1, $+[0] - 1);
            next unless $callee =~ /^(?:wait|fulfillment$)/;
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

pass "test waits: no test sleeps on the real clock or races a wait against a numeric deadline"
