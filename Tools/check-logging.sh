#!/usr/bin/env bash
# `KernovaLogger.log(_:_:)` is the one logging spelling: it emits the local log
# record and, in a guest agent, forwards the same message to the host. A record
# emitted any other way never leaves the guest, and from the sandboxed app
# console output reaches no one.
#
# Scope is every tracked Swift file outside tests (a directory component
# ending in `Tests` or `TestSupport`, which may read the log store to check
# what `KernovaLogger` emitted) and outside KernovaLogging, which implements
# `KernovaLogger` over the platform. Two findings:
#
# - Emitting through the platform log: `Logger` (`os.Logger`), `os_log…`,
#   `OSLog(`, `NSLog…`, `syslog`, `vsyslog`, `openlog`. Importing `os` is
#   not one — `os_unfair_lock` lives there.
# - Console output: a bare or `Swift.`-qualified `print`, `debugPrint` or
#   `dump`, `FileHandle.standardOutput`/`.standardError`, C's `stdout`,
#   `stderr`, `STDOUT_FILENO`, `STDERR_FILENO`, `printf`, `puts`, `putchar`,
#   `perror`. Console output is a command-line program's interface, so the
#   targets that hold a command-line mode are exempt from this finding: the
#   `kernova` CLI (KernovaCLI, KernovaCLICore), `kernova-bench`
#   (KernovaBench), Tools/, and the guest agents' version, self-test and
#   install modes (KernovaLinuxAgent, KernovaPlatformDarwin, KernovaMacOSAgent).
#   The agents' targets hold runtime code beside those modes, which the
#   exemption leaves unchecked for console output.
#
# A member call (`view.print(`, `process.standardError = …`) is not matched.
# String literals and comments are blanked before matching, so prose may name
# what it forbids. Given file arguments, it classifies each by its path as
# written, relative to the repository root, and scans those instead; its
# fixture test drives it that way. Reports every finding before failing, and
# fails on a file it could not read.

set -uo pipefail

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
    done < <(git ls-files '*.swift')
fi

findings=$(perl -e '
    use strict;
    use warnings;

    # As in check-config-decoding.sh: each literal or comment in source
    # order, raw and multi-line strings before plain ones.
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

    my $exempt = qr{
        ^KernovaKit/Sources/KernovaLogging/
      | (?:^|/) [^/]* (?:Tests|TestSupport) /
    }x;
    my $console_exempt = qr{
        ^Tools/
      | ^KernovaCLI/
      | ^KernovaMacOSAgent/
      | ^KernovaKit/Sources/(?:KernovaCLICore|KernovaBench|KernovaLinuxAgent|KernovaPlatformDarwin)/
    }x;

    my $log_api = qr{
        (?<![\w.]) (?: os \s* \. \s* )? Logger \b
      | \b (?: os_log\w* | NSLog\w* ) \b
      | \b OSLog \s* \(
      | (?<![\w.]) (?: syslog | vsyslog | openlog ) \s* \(
    }x;

    my $console = qr{
        (?<![\w.]) (?: Swift \s* \. \s* )? (?: print | debugPrint | dump ) \s* \(
      | \b FileHandle \s* \. \s* standard (?: Output | Error ) \b
      | (?<![\w.]) (?: stdout | stderr | STDOUT_FILENO | STDERR_FILENO ) \b
      | (?<![\w.]) (?: printf | puts | putchar | perror ) \s* \(
    }x;

    sub line_at { my ($code, $offset) = @_; return (substr($code, 0, $offset) =~ tr/\n//) + 1 }

    my $failed = 0;
    for my $arg (@ARGV) {
        my $path = $arg =~ s{^\./}{}r;
        next if $path =~ $exempt;
        my $check_console = $path !~ $console_exempt;

        my $code;
        if (open(my $fh, "<", $arg)) {
            local $/;
            $code = <$fh>;
            close $fh;
        }
        unless (defined $code) {
            print STDERR "check-logging: cannot read $arg: $!\n";
            $failed = 1;
            next;
        }
        $code =~ s{$blankable}{
            my $kept = $&;
            $kept =~ tr/\n//cd;
            (defined $+{string} ? q{""} : q{ }) . $kept
        }ge;

        my %found;
        while ($code =~ m{$log_api}g) {
            $found{line_at($code, $-[0])} //= "the platform log API; log through KernovaLogger.log(_:_:)";
        }
        if ($check_console) {
            while ($code =~ m{$console}g) {
                $found{line_at($code, $-[0])} //= "console output outside a command-line interface; log through KernovaLogger.log(_:_:)";
            }
        }
        print "$arg:$_ — $found{$_}\n" for sort { $a <=> $b } keys %found;
    }
    exit($failed ? 2 : 0);
' -- "${files[@]}")
scan_status=$?

if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | while IFS= read -r line; do
        echo "check-logging: $line" >&2
    done
fi

if [ "$scan_status" -ne 0 ]; then
    echo "check-logging: the scan exited $scan_status — at least one file went unread" >&2
    exit 1
fi

[ -z "$findings" ] || exit 1

pass "logging: outside tests, only KernovaLogging emits to the platform log, and console output stays in command-line targets"
