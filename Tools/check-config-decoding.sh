#!/usr/bin/env bash
# A persisted field with a default decodes through the config-field forms in
# KernovaKit/Sources/KernovaKit/ConfigFileDecoding.swift. Spelled as a
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
# forms are built from that spelling. Given file arguments — relative ones
# resolved against the caller's working directory — it scans those instead,
# with no exemption; its fixture test drives it that way. A file it cannot
# read fails the check.
#
# String literals and comments are blanked in one left-to-right pass before
# matching, so prose may name what it forbids and a string's `//` or `)`
# changes nothing around it.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
caller_dir="$PWD"

cd "$(git rev-parse --show-toplevel)" || exit 1

# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

helper='KernovaKit/Sources/KernovaKit/ConfigFileDecoding.swift'

if [ "$#" -gt 0 ]; then
    files=("$@")
    base="$caller_dir"
else
    files=()
    while IFS= read -r file; do
        [ "$file" = "$helper" ] || files+=("$file")
    done < <(git ls-files '*.swift')
    base="$PWD"
fi

findings=$(CHECK_BASE="$base" perl -e '
    use strict;
    use warnings;
    use File::Spec;

    # Each literal or comment, in source order, so whichever starts first
    # wins: a `//` inside a string is no comment, a quote inside a comment
    # opens no string. Raw and multi-line strings before plain ones, which
    # would otherwise take their opening quotes.
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

    my $failed = 0;
    for my $arg (@ARGV) {
        my $path = File::Spec->rel2abs($arg, $ENV{CHECK_BASE});
        my $code;
        if (open(my $fh, "<", $path)) {
            local $/;
            $code = <$fh>;
            close $fh;
        }
        unless (defined $code) {
            print STDERR "check-config-decoding: cannot read $arg: $!\n";
            $failed = 1;
            next;
        }
        # Blanked to what keeps the shape around it — an empty string, or a
        # space for a comment — plus every newline, so line numbers hold.
        $code =~ s{$blankable}{
            my $kept = $&;
            $kept =~ tr/\n//cd;
            (defined $+{string} ? q{""} : q{ }) . $kept
        }ge;
        while ($code =~ m{$decode}g) {
            my ($start, $end, $keyed) = ($-[0], $+[0], $+{keyed});
            next if defined $keyed && $keyed !~ /\bforKey\s*:/;
            next unless substr($code, $end) =~ m{\A$chain\?\?};
            my $line = (substr($code, 0, $start) =~ tr/\n//) + 1;
            print "$arg:$line\n";
        }
    }
    exit($failed ? 2 : 0);
' -- "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-config-decoding: $line — a decode with a ?? fallback; use a config-field form from $helper" >&2
    done
    exit 1
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-config-decoding: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

pass "config decoding: no decode with a ?? fallback outside the config-field forms"
