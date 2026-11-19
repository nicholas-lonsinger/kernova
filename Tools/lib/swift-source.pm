# Swift source as a lint rule reads it. Loaded by path, never run:
#
#     require "$lib_dir/swift-source.pm";
#     my $code = SwiftSource::blank($source);

package SwiftSource;

use strict;
use warnings;

# blank($source) — the source with every comment and every literal's text
# gone, so a rule's pattern meets only code. A string literal becomes `"…"`
# holding just its interpolations, each `\(` with its code verbatim and `)`; an
# extended regex literal (`#/…/#`) becomes `""`; a comment becomes one space.
# Every newline stays where it was, so a line number in the result is one in
# the source.
#
# A bare regex literal (`/…/`) is read as code: whether a `/` opens one
# depends on the token before it, which this does not track.
sub blank {
    my ($source) = @_;
    pos($source) = 0;
    return _code(\$source, 0);
}

# line_at($code, $offset) — the 1-based line holding $offset.
sub line_at {
    my ($code, $offset) = @_;
    return (substr($code, 0, $offset) =~ tr/\n//) + 1;
}

# Code from pos(), to the end of the source or, $nested, through the `)` that
# closes the interpolation it is in; returns the code, without that `)`.
sub _code {
    my ($s, $nested) = @_;
    my ($out, $depth) = ('', 0);
    while (1) {
        if ($nested ? $$s =~ /\G([^"#\/()]+)/gc : $$s =~ /\G([^"#\/]+)/gc) {
            $out .= $1;
        } elsif ($$s =~ /\G(\#*)("""|")/gc) {
            $out .= '"' . _string($s, length $1, length $2 == 3) . '"';
        } elsif ($$s =~ /\G\/\//gc) {
            $$s =~ /\G[^\n]*/gc;
            $out .= ' ';
        } elsif ($$s =~ /\G\/\*/gc) {
            $out .= ' ' . _block_comment($s);
        } elsif ($$s =~ /\G(\#+)\//gc) {
            $out .= '""' . _regex($s, length $1);
        } elsif ($$s =~ /\G\(/gc) {
            $depth++;
            $out .= '(';
        } elsif ($$s =~ /\G\)/gc) {
            return $out if $depth == 0;
            $depth--;
            $out .= ')';
        } elsif ($$s =~ /\G([#\/])/gc) {
            $out .= $1;
        } else {
            return $out;
        }
    }
}

my %closer;

# A string literal's body from pos(), just past its opening delimiter, through
# its closing one; returns its interpolations and newlines. A single-line
# string ends at a newline it cannot hold.
sub _string {
    my ($s, $hashes, $multiline) = @_;
    my $h = '#' x $hashes;
    my ($close, $introducer) = @{ $closer{"$hashes $multiline"} //= [
        $multiline ? qr/\G"""$h/ : qr/\G"$h/,
        qr/\G\\$h/,
    ] };
    my $out = '';
    while (1) {
        if ($$s =~ /\G[^"\\\n]+/gc) {
        } elsif ($$s =~ /\G\n/gc) {
            if (!$multiline) { pos($$s)--; return $out }
            $out .= "\n";
        } elsif ($$s =~ /$close/gc) {
            return $out;
        } elsif ($$s =~ /\G"/gc) {
        } elsif ($$s =~ /$introducer/gc) {
            if ($$s =~ /\G\(/gc) {
                $out .= '\(' . _code($s, 1) . ')';
            } else {
                $$s =~ /\G[^\n]/gc;
            }
        } elsif ($$s =~ /\G\\/gc) {
        } else {
            return $out;
        }
    }
}

# A block comment's body from pos(), just past its `/*`, through the `*/` that
# closes it; returns its newlines.
sub _block_comment {
    my ($s) = @_;
    my ($out, $depth) = ('', 1);
    while ($depth) {
        if ($$s =~ /\G[^\/*\n]+/gc) {
        } elsif ($$s =~ /\G\n/gc) {
            $out .= "\n";
        } elsif ($$s =~ /\G\/\*/gc) {
            $depth++;
        } elsif ($$s =~ /\G\*\//gc) {
            $depth--;
        } elsif ($$s =~ /\G[\/*]/gc) {
        } else {
            last;
        }
    }
    return $out;
}

# An extended regex literal's body from pos(), just past its `#…/`, through
# its `/#…`; returns its newlines. A backslash escapes the character after it.
sub _regex {
    my ($s, $hashes) = @_;
    my $h = '#' x $hashes;
    my $out = '';
    while (1) {
        if ($$s =~ /\G[^\/\\\n]+/gc) {
        } elsif ($$s =~ /\G\n/gc) {
            $out .= "\n";
        } elsif ($$s =~ /\G\/$h/gc) {
            return $out;
        } elsif ($$s =~ /\G\\([^\n])?/gc) {
        } elsif ($$s =~ /\G\//gc) {
        } else {
            return $out;
        }
    }
}

1;
