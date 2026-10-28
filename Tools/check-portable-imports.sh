#!/usr/bin/env bash
# Off Apple platforms, `Foundation` is swift-corelibs-foundation, which links
# FoundationInternationalization and ICU — tens of megabytes in a static
# binary — where FoundationEssentials carries the types the portable targets
# use. So a portable target imports Foundation only as the fallback of
#
#     #if canImport(FoundationEssentials)
#     import FoundationEssentials
#     #else
#     import Foundation
#     #endif
#
# and never imports FoundationInternationalization. Every spelling of the
# import is matched — `@_exported`, `@preconcurrency`, `import struct
# Foundation.Data`, a submodule — and the fallback form is matched as those
# five lines exactly.
#
# Usage: Tools/check-portable-imports.sh <target>...
#   the targets whose sources (KernovaKit/Sources/<target>) to scan; the
#   Makefile passes its PORTABLE_TARGETS. A named target with no directory is
#   a failure, so a renamed target cannot drop out of the scan in silence.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

if [ "$#" -eq 0 ]; then
    echo "check-portable-imports: no targets named" >&2
    exit 2
fi

status=0
files=()
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
[ "${#files[@]}" -gt 0 ] || { pass "portable imports: no Swift sources in $*"; exit 0; }

findings=$(perl -ne '
    BEGIN { @window = () }
    my $import = qr{^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?};
    chomp(my $line = $_);
    push @window, $line;
    shift @window if @window > 4;
    if ($line =~ /${import}FoundationInternationalization\b/) {
        print "$ARGV:$.: imports FoundationInternationalization\n";
    } elsif ($line =~ /${import}Foundation(?:\.\w+)*\s*(?:\/\/.*)?$/) {
        my @before = @window[0 .. $#window - 1];
        my $guarded = @before == 3
            && $before[0] =~ /^#if canImport\(FoundationEssentials\)\s*$/
            && $before[1] =~ /^import FoundationEssentials\s*$/
            && $before[2] =~ /^#else\s*$/
            && $line =~ /^import Foundation\s*$/;
        $pending{$ARGV} = $. if $guarded;
        print "$ARGV:$.: imports Foundation outside the #else of #if canImport(FoundationEssentials)\n"
            unless $guarded;
    } elsif (exists $pending{$ARGV}) {
        print "$ARGV:$pending{$ARGV}: the fallback import Foundation is not followed by #endif\n"
            unless $line =~ /^#endif\s*$/;
        delete $pending{$ARGV};
    }
    if (eof) { close ARGV; @window = () }
' "${files[@]}") || {
    echo "check-portable-imports: could not read the sources" >&2
    exit 1
}

if [ -n "$findings" ]; then
    echo "check-portable-imports: a portable target imports Foundation in a form that links ICU off Apple platforms:" >&2
    printf '%s\n' "$findings" | sed 's/^/  /' >&2
    exit 1
fi

pass "portable imports: Foundation only as the FoundationEssentials fallback in $*"
