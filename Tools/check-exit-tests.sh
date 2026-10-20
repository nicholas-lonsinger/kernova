#!/usr/bin/env bash
# A Swift Testing exit test runs its body in a child of the test process, and
# until the child's exec completes it holds a copy of every descriptor the
# parent holds: POSIX_SPAWN_CLOEXEC_DEFAULT closes them only at exec
# (posix_spawnattr_setflags(3)). Inside that window a socket another test in
# the same process closed is still open in the child, so a check resting on the
# last reference dropping — the peer reading EOF, a write failing once the peer
# closed — sees the socket alive. A test target runs in a process of its own,
# under the test plan and under `swift test`, so the exit tests live in one
# target that holds nothing else: KernovaKit/Tests/KernovaKitExitTests.
#
# A finding is a `processExitsWith` outside that directory, or a `@Test` inside
# it whose body holds none. Scope is every tracked Swift file; string literals
# and comments are blanked before matching, so prose may name what it forbids.
# Reports every finding before failing, and fails on a file it could not read.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

exit_test_root='KernovaKit/Tests/KernovaKitExitTests/'

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(git ls-files '*.swift')

findings=$(perl -e '
    use strict;
    use warnings;

    my $root = shift @ARGV;

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

    my $exit_test = qr{\bprocessExitsWith\b};

    sub line_at { my ($code, $offset) = @_; return (substr($code, 0, $offset) =~ tr/\n//) + 1 }

    # The offset just past the bracketed span opening at $open, or undef
    # when it never closes.
    sub past_balanced {
        my ($code, $open, $opener, $closer) = @_;
        my $depth = 0;
        for (my $i = $open; $i < length $code; $i++) {
            my $c = substr($code, $i, 1);
            if ($c eq $opener) { $depth++ }
            elsif ($c eq $closer && --$depth == 0) { return $i + 1 }
        }
        return undef;
    }

    # The body of the function a `@Test` attribute ending at $from annotates:
    # past the arguments of the attribute, the first `{` outside the
    # parentheses of the signature.
    sub test_body {
        my ($code, $from) = @_;
        pos($code) = $from;
        if ($code =~ /\G\s*\(/gc) {
            $from = past_balanced($code, pos($code) - 1, "(", ")") // return undef;
        }
        pos($code) = $from;
        $code =~ /\bfunc\b/g or return undef;
        my $depth = 0;
        for (my $i = pos($code); $i < length $code; $i++) {
            my $c = substr($code, $i, 1);
            if ($c eq "(") { $depth++ }
            elsif ($c eq ")") { $depth-- }
            elsif ($c eq "{" && $depth == 0) {
                my $end = past_balanced($code, $i, "{", "}") // return undef;
                return substr($code, $i, $end - $i);
            }
        }
        return undef;
    }

    my $failed = 0;
    for my $file (@ARGV) {
        my $code;
        if (open(my $fh, "<", $file)) {
            local $/;
            $code = <$fh>;
            close $fh;
        }
        unless (defined $code) {
            print STDERR "check-exit-tests: cannot read $file: $!\n";
            $failed = 1;
            next;
        }
        $code =~ s{$blankable}{
            my $kept = $&;
            $kept =~ tr/\n//cd;
            (defined $+{string} ? q{""} : q{ }) . $kept
        }ge;

        my %found;
        if (index($file, $root) == 0) {
            while ($code =~ /\@Test\b/g) {
                my $start = $-[0];
                my $body = test_body($code, pos($code));
                next if defined $body && $body =~ $exit_test;
                $found{line_at($code, $start)} //= "a test that is not an exit test, in the exit-test target; it belongs in another test target";
            }
        } else {
            while ($code =~ /$exit_test/g) {
                $found{line_at($code, $-[0])} //= "an exit test outside $root; its child would inherit the descriptors of every other test in this process";
            }
        }

        print "$file:$_ — $found{$_}\n" for sort { $a <=> $b } keys %found;
    }
    exit($failed ? 2 : 0);
' -- "$exit_test_root" "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-exit-tests: $line" >&2
    done
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-exit-tests: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

[ -z "$findings" ] || exit 1

pass "exit tests: every exit test, and nothing else, is in ${exit_test_root%/}"
