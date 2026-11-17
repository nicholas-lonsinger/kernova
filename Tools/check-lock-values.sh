#!/usr/bin/env bash
# A lock box hands its body the stored value `inout`. When that value is a
# function, an Optional of one, or a tuple with a function element, Swift
# reabstracts the function on the way into the body and writes the wrapped
# function back on the way out, so every `withLock` leaves the stored function
# one thunk pair deeper for good: calls through it slow down, memory grows,
# and a thread eventually overflows its stack. Measured as 2N + constant
# frames after N holds with Swift 6.4.2, on `Locked` and on
# `Synchronization.Mutex` alike, at -Onone and -O. A function held in a struct
# field, an array or a dictionary keeps its depth.
#
# The finding is a `Locked<…>` or `Mutex<…>` whose type argument spells a
# function type outside any `[…]` and outside any generic argument list but
# `Optional<…>`'s. A function type reached through a typealias, or inferred
# from the box's initial value, is not spelled and so not seen.
#
# Scope is every tracked Swift file. String literals and comments are blanked
# before matching, so prose may name what it forbids. Given file arguments, it
# scans those instead; its fixture test drives it that way. Reports every
# finding before failing, and fails on a file it could not read.

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
    done < <(git ls-files '*.swift')
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

    sub line_at { my ($code, $offset) = @_; return (substr($code, 0, $offset) =~ tr/\n//) + 1 }

    # Whether the type argument starting at $start, just past the box`s `<`,
    # spells a function type where the box stores it directly. @open holds
    # each enclosing bracket that hides one: `[` and a generic `<`.
    sub stores_function {
        my ($code, $start) = @_;
        my (@open, $hidden);
        $hidden = 0;
        pos($code) = $start;
        while ($code =~ m{\G (?: (?<arrow> -> ) | (?<optional> \b Optional \s* < ) | (?<bracket> [<>()\[\]] ) | [^<>()\[\]-]+ | - ) }xgc) {
            if (defined $+{arrow}) {
                return 1 unless $hidden;
            } elsif (defined $+{optional}) {
                push @open, 0;
            } elsif (defined $+{bracket}) {
                my $bracket = $+{bracket};
                if ($bracket eq "(") {
                    push @open, 0;
                } elsif ($bracket eq "[" || $bracket eq "<") {
                    push @open, 1;
                    $hidden++;
                } else {
                    return 0 unless @open;
                    $hidden -= pop @open;
                }
            }
        }
        return 0;
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
            print STDERR "check-lock-values: cannot read $arg: $!\n";
            $failed = 1;
            next;
        }
        $code =~ s{$blankable}{
            my $kept = $&;
            $kept =~ tr/\n//cd;
            (defined $+{string} ? q{""} : q{ }) . $kept
        }ge;

        my %found;
        while ($code =~ m{(?<![\w.]) (?: Locked | Mutex ) \s* <}xg) {
            my ($at, $argument) = ($-[0], $+[0]);
            $found{line_at($code, $at)} = 1 if stores_function($code, $argument);
            pos($code) = $argument;
        }
        print "$arg:$_ — a lock box storing a function directly, which every withLock deepens; hold it in a struct field\n"
            for sort { $a <=> $b } keys %found;
    }
    exit($failed ? 2 : 0);
' -- "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-lock-values: $line" >&2
    done
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-lock-values: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

[ -z "$findings" ] || exit 1

pass "lock values: no Locked or Mutex stores a function, an Optional of one, or a tuple holding one"
