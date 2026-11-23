#!/usr/bin/env bash
# A persisted field with a default decodes through the config-field forms in
# KernovaKit/Sources/KernovaCommandModel/ConfigFileDecoding.swift. Spelled as a
# fallback after the decode instead, it decodes the same in a strict read, but
# File > Check Config Files cannot repair a bad value in it: only those forms
# record one with its repair.
#
# Flagged, in every tracked Swift file but that one: `??` after a
# `decodeIfPresent(…)` call, or after a `try?` keyed `decode(…, forKey: …)`
# call — past any closing parentheses, whitespace and line breaks, and any
# chain of `.member`, `?.member`, calls and trailing closures between them.
# Line comments are stripped first, so prose may name what this forbids.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

helper='KernovaKit/Sources/KernovaCommandModel/ConfigFileDecoding.swift'

findings=$(git ls-files -z '*.swift' | HELPER=$helper perl -0 -ne '
    BEGIN {
        our $chain = qr{
            (?(DEFINE)
                (?<p> \( (?: [^()]++ | (?&p) )*+ \) )
                (?<b> \{ (?: [^{}]++ | (?&b) )*+ \} )
            )
            (?: [\s)!]++ | \?? \s* \. \s* \w+ (?: \s* (?: (?&p) | (?&b) ) )* )*
        }x;
        our $decode = qr{
            (?(DEFINE)
                (?<args> \( (?: [^()]++ | (?&args) )*+ \) )
            )
            (?: \bdecodeIfPresent \s* (?&args)
              | \btry\? \s* (?: \w+ (?: \s* (?&args) )? \s* \. \s* )*? decode \s* (?<keyed> (?&args) )
            )
        }x;
    }
    chomp(my $path = $_);
    next if $path eq $ENV{HELPER};
    open(my $fh, "<", $path) or do { print STDERR "check-config-decoding: cannot read $path: $!\n"; $failed = 1; next };
    my $code = do { local $/; <$fh> };
    close $fh;
    # A string literal is kept whole, so a "//" in it starts no comment.
    $code =~ s{("(?:\\.|[^"\\\n])*")|//[^\n]*}{$1 // ""}ge;
    while ($code =~ m{$decode}g) {
        my ($start, $end, $keyed) = ($-[0], $+[0], $+{keyed});
        next if defined $keyed && $keyed !~ /\bforKey\s*:/;
        next unless substr($code, $end) =~ m{\A$chain\?\?};
        printf "  %s:%d\n", $path, (substr($code, 0, $start) =~ tr/\n//) + 1;
    }
    END { $? = $failed ? 2 : 0 }
')
status=$?

if [ -n "$findings" ]; then
    echo "check-config-decoding: a decode with a ?? fallback; use a config-field form from $helper:" >&2
    printf '%s\n' "$findings" >&2
    exit 1
fi
[ "$status" -eq 0 ] || exit 1
pass 'config decoding: no decode with a ?? fallback outside the config-field forms'
