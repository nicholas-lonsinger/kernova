#!/usr/bin/env bash
# Holds the Swift sources to the rules in Tools/swift-rules/, each a
# <name>.pm whose header says what it enforces. Every file is read and blanked
# (Tools/lib/swift-source.pm) once, and each rule matches the result, so prose
# and string literals may name what a rule forbids.
#
# A rule file returns a hash. `check`, given a file's path, its blanked code
# and its source, returns [line, what] for each finding; `pass` is the line
# printed when it finds none; `scope`, given a tracked path, says whether the
# rule reads that file, and is every file when absent.
#
# Usage:
#   Tools/check-swift-sources.sh [--rule <name>]... [<file>...]
#     Runs the named rules, or every rule. With no file, each rule reads the
#     tracked Swift files in its scope; given files, every rule reads those,
#     and a rule that classifies a file by its path takes the path as given,
#     relative to the repository root.
#
# Reports every finding before failing, and fails on a file it could not read.

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

rules=()
while [ "$#" -gt 0 ] && [ "$1" = --rule ]; do
    [ "$#" -ge 2 ] || { echo 'check-swift-sources: --rule needs a rule name' >&2; exit 2; }
    rules+=("$2")
    shift 2
done

if [ "$#" -gt 0 ]; then
    tree=0
    files=("$@")
else
    tree=1
    top=$(git rev-parse --show-toplevel) || exit 1
    cd "$top" || exit 1
    listing=$(git ls-files '*.swift') || exit 1
    files=()
    while IFS= read -r file; do
        [ -z "$file" ] || files+=("$file")
    done <<<"$listing"
fi

# One tab-separated line per outcome, in rule order: `finding <rule> <text>`,
# `unread <file>: <reason>` or `pass <text>`.
report=$(perl -e '
    use strict;
    use warnings;
    use File::Glob qw(bsd_glob);

    my ($tools, $tree, $wanted, @files) = @ARGV;
    require "$tools/lib/swift-source.pm";

    my %rule;
    for my $file (bsd_glob("$tools/swift-rules/*.pm")) {
        my ($name) = $file =~ m{([^/]+)\.pm\z};
        my $rule = do $file;
        die "check-swift-sources: $file: ", ($@ || (defined $rule ? "returns no rule" : $!)), "\n" unless ref $rule eq "HASH";
        $rule{$name} = $rule;
    }
    my @names = $wanted ne "" ? split(/ /, $wanted) : sort keys %rule;
    for my $name (@names) {
        die "check-swift-sources: no rule named $name; the rules are ", join(", ", sort keys %rule), "\n" unless $rule{$name};
    }

    my (%found, %unread);
    for my $file (@files) {
        my @reading = grep { !$tree || !$rule{$_}{scope} || $rule{$_}{scope}->($file) } @names;
        next unless @reading;
        my $source;
        if (open(my $fh, "<", $file)) {
            local $/;
            $source = <$fh>;
            close $fh;
        }
        unless (defined $source) {
            print "unread\t$file: $!\n";
            $unread{$_} = 1 for @reading;
            next;
        }
        my $code = SwiftSource::blank($source);
        for my $name (@reading) {
            my %at;
            for my $finding ($rule{$name}{check}->($file, $code, $source)) {
                $at{$finding->[0]} //= $finding->[1];
            }
            push @{ $found{$name} }, map { "$file:$_ — $at{$_}" } sort { $a <=> $b } keys %at if %at;
        }
    }

    for my $name (@names) {
        if ($found{$name}) {
            print "finding\t$name\t$_\n" for @{ $found{$name} };
        } elsif (!$unread{$name}) {
            print "pass\t$rule{$name}{pass}\n";
        }
    }
    exit(%found || %unread ? 1 : 0);
' -- "$lib_dir" "$tree" "${rules[*]-}" ${files[@]+"${files[@]}"})
status=$?

while IFS=$'\t' read -r kind first rest; do
    case "$kind" in
        finding) echo "check-$first: $rest" >&2 ;;
        unread) echo "check-swift-sources: cannot read $first" >&2 ;;
        pass) pass "$first" ;;
    esac
done <<<"$report"

case "$status" in
    0 | 1) exit "$status" ;;
    *)
        echo "check-swift-sources: the rules stopped with status $status" >&2
        exit 1
        ;;
esac
