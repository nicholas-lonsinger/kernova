#!/usr/bin/env bash
# Holds the Swift sources to the rules in Tools/swift-rules/, each a
# <name>.pm whose header says what it enforces. `dead-code-sources blank`
# (Tools/DeadCode) reads and parses each file once, through swift-syntax, and
# every rule matches the blanked text it writes, so prose and string literals
# may name what a rule forbids.
#
# A rule file returns a hash. `check`, given a file's path, its blanked text
# and its bytes, returns [line, what] for each finding, and may call
# `line_at($text, $offset)` for the line an offset is on; `pass` is the line
# printed when it finds none; `scope`, given a tracked path, says whether the
# rule reads that file, and is every file when absent.
#
# Usage:
#   Tools/check-swift-sources.sh [--tool <path>] [--rule <name>]... [<file>...]
#     Runs the named rules, or every rule. With no file, each rule reads the
#     tracked Swift files in its scope; given files, every rule reads those,
#     and a rule that classifies a file by its path takes the path as given,
#     relative to the repository root. --tool runs that dead-code-sources in
#     place of the release build in the machine's tool cache.
#
# Reports every finding before failing, and fails on a file it could not read
# or parse.
#
# make lint: runs last — a cold tool cache builds dead-code-sources in release (minutes)

set -uo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${lib_dir%/*}"
# shellcheck source=lib/output.sh
. "$lib_dir/lib/output.sh"

usage() {
    echo 'usage: Tools/check-swift-sources.sh [--tool <path>] [--rule <name>]... [<file>...]' >&2
    exit 2
}

# The rules this checkout tracks, whatever repository the caller is in: a
# hook's GIT_DIR names the caller's.
tracked_rules() (
    # shellcheck disable=SC2046 # one variable name per word
    unset $(git rev-parse --local-env-vars)
    git -C "$root" ls-files -- ':(glob)Tools/swift-rules/*.pm'
)
names=()
while IFS= read -r file; do
    file=${file##*/}
    [ -z "$file" ] || names+=("${file%.pm}")
done <<<"$(tracked_rules)"
[ "${#names[@]}" -gt 0 ] || { echo 'check-swift-sources: git tracks no Tools/swift-rules/*.pm' >&2; exit 1; }

tool=''
rules=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tool)
            [ "$#" -ge 2 ] || usage
            tool=$2
            ;;
        --rule)
            [ "$#" -ge 2 ] || usage
            case " ${names[*]} " in
                *" $2 "*) rules+=("$2") ;;
                *)
                    echo "check-swift-sources: no rule named $2; the rules are ${names[*]}" >&2
                    exit 2
                    ;;
            esac
            ;;
        --*) usage ;;
        *) break ;;
    esac
    shift 2
done
[ "${#rules[@]}" -gt 0 ] || rules=("${names[@]}")
rule_files=()
for rule in "${rules[@]}"; do rule_files+=("$root/Tools/swift-rules/$rule.pm"); done

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

if [ -z "$tool" ]; then
    # shellcheck source=lib/dead-code-tool.sh
    . "$lib_dir/lib/dead-code-tool.sh"
    tool=$(installed_dead_code_sources) || {
        echo 'check-swift-sources: dead-code-sources does not install, so no rule read a file' >&2
        exit 1
    }
fi

# One tab-separated line per outcome, in rule order: `finding <rule> <text>`,
# `failed <why a file went unread>` or `pass <text>`. Exits 2 having said why
# when it stops before every rule has read every file.
report=$(perl -e '
    use strict;
    use warnings;

    sub line_at { my ($text, $offset) = @_; return (substr($text, 0, $offset) =~ tr/\n//) + 1 }

    # read_exactly($handle, $length) — the next $length bytes, or dies.
    sub read_exactly {
        my ($handle, $length) = @_;
        my $bytes = "";
        while (length $bytes < $length) {
            my $got = read($handle, $bytes, $length - length $bytes, length $bytes);
            die "dead-code-sources blank stopped mid-record\n" unless $got;
        }
        return $bytes;
    }

    eval {
        my ($tool, $tree, $count, @rest) = @ARGV;
        my @rule_files = splice(@rest, 0, $count);
        my @files = @rest;

        my (%rule, @names);
        for my $file (@rule_files) {
            my ($name) = $file =~ m{([^/]+)\.pm\z};
            my $rule = do $file;
            die "$file: ", ($@ || (defined $rule ? "returns no rule" : "$!")), "\n" unless ref $rule eq "HASH";
            die "$file: its rule has no check\n" unless ref $rule->{check} eq "CODE";
            die "$file: its rule has no pass line\n" unless defined $rule->{pass} && !ref $rule->{pass};
            die "$file: its rule has a scope that is no function\n" if defined $rule->{scope} && ref $rule->{scope} ne "CODE";
            $rule{$name} = $rule;
            push @names, $name;
        }

        my %reading;
        my @todo = grep {
            my $file = $_;
            $reading{$file} = [grep { !$tree || !$rule{$_}{scope} || $rule{$_}{scope}->($file) } @names];
            @{ $reading{$file} };
        } @files;

        my (%found, %failed);
        if (@todo) {
            open(my $records, "-|", $tool, "blank", @todo) or die "cannot run $tool: $!\n";
            binmode $records;
            for my $file (@todo) {
                my $header = <$records>;
                die "dead-code-sources blank stopped before $file\n" unless defined $header;
                my ($kind, @lengths) = $header =~ /\A(blanked|unread|unparsed) (\d+) (\d+) (\d+)\n\z/
                    or die "dead-code-sources blank wrote no record for $file\n";
                my ($path, $source, $text) = map { read_exactly($records, $_) } @lengths;
                die "dead-code-sources blank wrote $path where $file was due\n" unless $path eq $file;
                if ($kind ne "blanked") {
                    print "failed\t$text\n";
                    $failed{$_} = 1 for @{ $reading{$file} };
                    next;
                }
                for my $name (@{ $reading{$file} }) {
                    my %at;
                    for my $finding ($rule{$name}{check}->($file, $text, $source)) {
                        $at{$finding->[0]} //= $finding->[1];
                    }
                    push @{ $found{$name} }, map { "$file:$_ — $at{$_}" } sort { $a <=> $b } keys %at if %at;
                }
            }
            close $records or die "dead-code-sources blank ended with status $?\n";
        }

        for my $name (@names) {
            if ($found{$name}) {
                print "finding\t$name\t$_\n" for @{ $found{$name} };
            } elsif (!$failed{$name}) {
                print "pass\t$rule{$name}{pass}\n";
            }
        }
        exit(%found || %failed ? 1 : 0);
    };
    print STDERR "check-swift-sources: $@";
    exit 2;
' -- "$tool" "$tree" "${#rule_files[@]}" "${rule_files[@]}" ${files[@]+"${files[@]}"})
status=$?

while IFS=$'\t' read -r kind first rest; do
    case "$kind" in
        finding) echo "check-$first: $rest" >&2 ;;
        failed) echo "check-swift-sources: $first" >&2 ;;
        pass) pass "$first" ;;
    esac
done <<<"$report"

case "$status" in
    0 | 1) exit "$status" ;;
    2) exit 1 ;;
    *)
        echo "check-swift-sources: the rules stopped with status $status" >&2
        exit 1
        ;;
esac
