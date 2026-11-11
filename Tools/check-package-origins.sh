#!/usr/bin/env bash
# Every remote Swift package comes from a GitHub organization in
# allowed_orgs below. A package from any other organization or host takes the
# maintainer's explicit sign-off, and granting it means adding the organization
# here.
#
# Reads every place a remote package is declared or pinned:
#
# - each tracked Package.swift: every `.package(url:)` must name an allowed
#   organization; `.package(path:)` is local; `.package(id:)` comes from a
#   registry, not GitHub, so it is a finding.
# - each tracked Package.resolved: every pin's `location`, transitive pins
#   included — a dependency's dependency is still code from that organization.
# - Kernova.xcodeproj/project.pbxproj: every XCRemoteSwiftPackageReference's
#   `repositoryURL`.
#
# A source this check cannot read fully — a `.package(` form it does not know,
# a pin or remote reference without a location — is a finding, so a format
# change cannot shrink what it checks. Given file arguments, it classifies each
# by its name and reads those instead; its fixture test drives it that way.
# Reports every finding before failing.

set -uo pipefail

allowed_orgs="apple swiftlang swift-server"

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
    done < <(git ls-files '*Package.swift' '*Package.resolved' '*.xcodeproj/project.pbxproj')
fi

# One line per reference: <file>:<line><TAB><url or finding>, where a finding
# starts with "!".
references=$(perl -e '
    use strict;
    use warnings;

    sub line_at { my ($text, $offset) = @_; return (substr($text, 0, $offset) =~ tr/\n//) + 1 }

    my $failed = 0;
    for my $file (@ARGV) {
        my $text;
        if (open(my $fh, "<", $file)) {
            local $/;
            $text = <$fh>;
            close $fh;
        }
        unless (defined $text) {
            print STDERR "check-package-origins: cannot read $file: $!\n";
            $failed = 1;
            next;
        }

        if ($file =~ m{(?:^|/)Package\.swift$}) {
            # Comments blanked, strings kept: a URL holds "//".
            $text =~ s{
                (?<string> " (?: \\. | [^"\\\n] )* " )
              | (?<comment> //[^\n]* | /\* .*? \*/ )
            }{
                defined $+{string} ? $+{string} : ($& =~ tr/\n//cdr)
            }gsex;
            while ($text =~ m{\.package\s*\(}g) {
                my $start = $-[0];
                my $line = line_at($text, $start);
                my $rest = substr($text, $+[0]);
                if ($rest =~ m{\A\s*(?:name\s*:\s*"[^"]*"\s*,\s*)?(url|path|id)\s*:\s*"([^"]*)"}) {
                    my ($label, $value) = ($1, $2);
                    next if $label eq "path";
                    print "$file:$line\t", ($label eq "url" ? $value : "!a registry package ($value), not a GitHub repository"), "\n";
                } else {
                    print "$file:$line\t!a .package( form this check does not read\n";
                }
            }
        } elsif ($file =~ m{(?:^|/)Package\.resolved$}) {
            my $pins = () = $text =~ m{"identity"\s*:}g;
            my $found = 0;
            while ($text =~ m{"location"\s*:\s*"([^"]*)"}g) {
                $found++;
                print "$file:", line_at($text, $-[0]), "\t$1\n";
            }
            print "$file:1\t!$pins pins but $found locations — a format this check does not read\n" if $pins != $found;
        } elsif ($file =~ m{\.pbxproj$}) {
            my $refs = () = $text =~ m{isa = XCRemoteSwiftPackageReference;}g;
            my $found = 0;
            while ($text =~ m{^\s*repositoryURL = "?([^";]*)"?;}mg) {
                $found++;
                print "$file:", line_at($text, $-[0]), "\t$1\n";
            }
            print "$file:1\t!$refs XCRemoteSwiftPackageReferences but $found repositoryURLs — a form this check does not read\n" if $refs != $found;
        } else {
            print STDERR "check-package-origins: $file is not a Package.swift, Package.resolved or project.pbxproj\n";
            $failed = 1;
        }
    }
    exit($failed ? 2 : 0);
' -- "${files[@]}")
scan_status=$?

findings=""
orgs=""
while IFS=$'\t' read -r where url; do
    [ -n "$where" ] || continue
    case "$url" in
        !*)
            findings="$findings$where — ${url#!}"$'\n'
            continue
            ;;
    esac
    org=$(printf '%s\n' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\.com[:/]([^/]+)/[^/]+$#\2#p' | tr '[:upper:]' '[:lower:]')
    if [ -z "$org" ]; then
        findings="$findings$where — $url is not a github.com repository"$'\n'
    elif [[ " $allowed_orgs " != *" $org "* ]]; then
        findings="$findings$where — $url is from the $org organization, outside $allowed_orgs"$'\n'
    else
        orgs="$orgs$org"$'\n'
    fi
done <<<"$references"

if [ -n "$findings" ]; then
    printf '%s' "$findings" | while IFS= read -r line; do
        echo "check-package-origins: $line" >&2
    done
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-package-origins: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

if [ -n "$findings" ]; then
    echo "check-package-origins: a package from outside $allowed_orgs takes the maintainer's sign-off, then its organization goes in this check's allowed_orgs" >&2
    exit 1
fi

used=$(printf '%s' "$orgs" | sort -u | paste -sd ' ' -)
pass "package origins: every remote package and pin in ${#files[@]} files is from an allowed GitHub organization (${used:-none in use})"
