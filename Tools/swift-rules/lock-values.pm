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

use strict;
use warnings;

# Whether the type argument starting at $start, just past the box's `<`,
# spells a function type where the box stores it directly. @open holds each
# enclosing bracket that hides one: `[` and a generic `<`.
my sub stores_function {
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

+{
    pass => 'lock values: no Locked or Mutex stores a function, an Optional of one, or a tuple holding one',
    check => sub {
        my ($path, $code) = @_;
        my @found;
        while ($code =~ m{(?<![\w.]) (?: Locked | Mutex ) \s* <}xg) {
            my ($at, $argument) = ($-[0], $+[0]);
            push @found, [SwiftSource::line_at($code, $at), "a lock box storing a function directly, which every withLock deepens; hold it in a struct field"]
                if stores_function($code, $argument);
            pos($code) = $argument;
        }
        return @found;
    },
};
