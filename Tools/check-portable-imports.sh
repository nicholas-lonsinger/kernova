#!/usr/bin/env bash
# Off Apple platforms, `Foundation` is swift-corelibs-foundation, which links
# FoundationInternationalization and ICU — tens of megabytes in a static
# binary — and FoundationNetworking and FoundationXML link it too, where
# FoundationEssentials carries the types the portable targets use. So a
# portable target imports a Foundation module only as
#
#     #if canImport(FoundationEssentials)
#     import FoundationEssentials
#     #else
#     import Foundation
#     #endif
#
# The check is structural rather than a list of bad spellings: a line in which
# the word `import` is followed by a `Foundation…` module fails unless it is
# exactly the second or fourth line of those five. Line comments are stripped
# first, so prose may name what it forbids. Tools/tests/check-portable-imports.sh
# holds a fixture per spelling.
#
# Usage:
#   Tools/check-portable-imports.sh <target>...
#     the targets whose tracked sources (KernovaKit/Sources/<target>) to scan;
#     the Makefile passes its PORTABLE_TARGETS. A named target with no
#     directory is a failure, so a renamed target cannot drop out in silence.
#   Tools/check-portable-imports.sh --files <file>...
#     scans those files instead; the fixture suite drives it this way.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

if [ "$#" -eq 0 ]; then
    echo "check-portable-imports: no targets named" >&2
    exit 2
fi

files=()
if [ "$1" = --files ]; then
    shift
    files=("$@")
    scope="the given files"
else
    cd "$(git rev-parse --show-toplevel)" || exit 1
    status=0
    for target in "$@"; do
        root="KernovaKit/Sources/$target"
        if [ ! -d "$root" ]; then
            echo "check-portable-imports: $root does not exist" >&2
            status=1
            continue
        fi
        while IFS= read -r file; do
            files+=("$file")
        done < <(git ls-files "$root/*.swift")
    done
    [ "$status" -eq 0 ] || exit "$status"
    scope="$*"
fi
[ "${#files[@]}" -gt 0 ] || { pass "portable imports: no Swift sources in $scope"; exit 0; }

findings=$(perl -e '
    my $failed = 0;
    for my $file (@ARGV) {
        open(my $fh, "<", $file) or do { print STDERR "cannot read $file\n"; $failed = 1; next };
        my @lines = map { s/\r?\n\z//r } <$fh>;
        close $fh;
        # Whether the guarded form starts at line index $s.
        my $form = sub {
            my $s = shift;
            return $s >= 0 && $s + 4 <= $#lines
                && $lines[$s] eq "#if canImport(FoundationEssentials)"
                && $lines[$s + 1] eq "import FoundationEssentials"
                && $lines[$s + 2] eq "#else"
                && $lines[$s + 3] eq "import Foundation"
                && $lines[$s + 4] eq "#endif";
        };
        for my $i (0 .. $#lines) {
            (my $code = $lines[$i]) =~ s{//.*}{};
            next unless $code =~ /\bimport\b.*\bFoundation\w*/;
            my $guarded = ($lines[$i] eq "import FoundationEssentials" && $form->($i - 1))
                || ($lines[$i] eq "import Foundation" && $form->($i - 3));
            print "$file:" . ($i + 1) . ": $lines[$i]\n" unless $guarded;
        }
    }
    exit $failed;
' "${files[@]}") || {
    echo "check-portable-imports: could not read the sources" >&2
    exit 1
}

if [ -n "$findings" ]; then
    echo "check-portable-imports: a Foundation module imported outside the FoundationEssentials-first form:" >&2
    printf '%s\n' "$findings" | sed 's/^/  /' >&2
    exit 1
fi

pass "portable imports: Foundation only as the FoundationEssentials fallback in $scope"
