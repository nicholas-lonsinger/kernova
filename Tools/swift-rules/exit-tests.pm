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
# it whose body holds none.

use strict;
use warnings;

my $target = 'KernovaKit/Tests/KernovaKitExitTests';
my $root = "$target/";
my $exit_test = qr{\bprocessExitsWith\b};

# The offset just past the bracketed span opening at $open, or undef when it
# never closes.
my sub past_balanced {
    my ($code, $open, $opener, $closer) = @_;
    my $depth = 0;
    for (my $i = $open; $i < length $code; $i++) {
        my $c = substr($code, $i, 1);
        if ($c eq $opener) { $depth++ }
        elsif ($c eq $closer && --$depth == 0) { return $i + 1 }
    }
    return undef;
}

# The body of the function a `@Test` attribute ending at $from annotates: past
# the arguments of the attribute, the first `{` outside the parentheses of the
# signature.
my sub test_body {
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

+{
    pass => "exit tests: every exit test, and nothing else, is in $target",
    check => sub {
        my ($path, $code) = @_;
        my @found;
        if (index($path, $root) == 0) {
            while ($code =~ /\@Test\b/g) {
                my $start = $-[0];
                my $body = test_body($code, pos($code));
                next if defined $body && $body =~ $exit_test;
                push @found, [SwiftSource::line_at($code, $start), "a test that is not an exit test, in the exit-test target; it belongs in another test target"];
            }
        } else {
            while ($code =~ /$exit_test/g) {
                push @found, [SwiftSource::line_at($code, $-[0]), "an exit test outside $root; its child would inherit the descriptors of every other test in this process"];
            }
        }
        return @found;
    },
};
