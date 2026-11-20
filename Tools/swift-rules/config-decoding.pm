# A persisted field with a default decodes through the config-field forms in
# KernovaKit/Sources/KernovaCommandModel/ConfigFileDecoding.swift. Spelled as a
# fallback after the decode instead, it decodes the same in a strict read, but
# File > Check Config Files cannot repair a bad value in it: only those forms
# record one with its repair.
#
# Flagged: `??` after a `decodeIfPresent(…)` call, or after a `try?` keyed
# `decode(…, forKey: …)` call — past any closing parentheses, whitespace and
# line breaks, and any chain of `.member`, `?.member`, calls and trailing
# closures (`.map { … }`) between them. A decode with no `??` after it is not
# flagged, nor is a `try?` decode of a whole value (no `forKey:`).
#
# Scope is every tracked Swift file but the helper itself, which is where the
# forms are built from that spelling.

use strict;
use warnings;

my $helper = 'KernovaKit/Sources/KernovaCommandModel/ConfigFileDecoding.swift';

my $chain = qr{
    (?(DEFINE)
        (?<p> \( (?: [^()]++ | (?&p) )*+ \) )
        (?<b> \{ (?: [^{}]++ | (?&b) )*+ \} )
    )
    (?: [\s)!]++ | \?? \s* \. \s* \w+ (?: \s* (?: (?&p) | (?&b) ) )* )*
}x;

my $decode = qr{
    (?(DEFINE)
        (?<args> \( (?: [^()]++ | (?&args) )*+ \) )
    )
    (?: \bdecodeIfPresent \s* (?&args)
      | \btry\? \s* (?: \w+ (?: \s* (?&args) )? \s* \. \s* )*? decode \s* (?<keyed> (?&args) )
    )
}x;

+{
    scope => sub { $_[0] ne $helper },
    pass => 'config decoding: no decode with a ?? fallback outside the config-field forms',
    check => sub {
        my ($path, $code) = @_;
        my @found;
        while ($code =~ m{$decode}g) {
            my ($start, $end, $keyed) = ($-[0], $+[0], $+{keyed});
            next if defined $keyed && $keyed !~ /\bforKey\s*:/;
            next unless substr($code, $end) =~ m{\A$chain\?\?};
            push @found, [line_at($code, $start), "a decode with a ?? fallback; use a config-field form from $helper"];
        }
        return @found;
    },
};
