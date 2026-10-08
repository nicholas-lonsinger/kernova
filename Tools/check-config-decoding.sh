#!/usr/bin/env bash
# A persisted field with a default decodes through the config-field forms in
# KernovaKit/Sources/KernovaKit/ConfigFileDecoding.swift. Spelled as
# `decodeIfPresent(…) ?? fallback` instead, it decodes the same in a strict
# read, but File > Check Config Files cannot repair a bad value in it: only
# those forms record one with its repair.
#
# Flagged: a `decodeIfPresent(` call whose closing parenthesis — after any
# further closing parentheses and whitespace, line breaks included — is
# followed by `??`. A bare `decodeIfPresent` with no `??` is not flagged.
#
# Scope is every tracked Swift file but the helper itself, which is where the
# forms are built from that spelling. Given file arguments, it scans those
# instead, with no exemption; its fixture test drives it that way.
#
# Line comments are stripped before matching, so prose may name what it
# forbids.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

helper='KernovaKit/Sources/KernovaKit/ConfigFileDecoding.swift'

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    files=()
    while IFS= read -r file; do
        [ "$file" = "$helper" ] || files+=("$file")
    done < <(git ls-files '*.swift')
fi

findings=$(perl -0777 -ne '
    my $code = $_;
    # Each line comment to its end, keeping the newline so line numbers hold.
    $code =~ s{//[^\n]*}{}g;
    while ($code =~ m{\bdecodeIfPresent\s*(\((?:[^()]++|(?1))*\))[\s)]*\?\?}g) {
        my $line = (substr($code, 0, $-[0]) =~ tr/\n//) + 1;
        print "$ARGV:$line\n";
    }
' -- "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-config-decoding: $line — decodeIfPresent(…) ?? …; use a config-field form from $helper" >&2
    done
    exit 1
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-config-decoding: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

pass "config decoding: no decodeIfPresent(…) ?? … outside the config-field forms"
