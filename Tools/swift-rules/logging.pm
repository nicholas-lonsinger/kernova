# `KernovaLogger.log(_:_:)` is the one logging spelling: it emits the local log
# record and, in a guest agent, forwards the same message to the host. A record
# emitted any other way never leaves the guest, and from the sandboxed app
# console output reaches no one.
#
# It holds for every Swift file, by its path relative to the repository root,
# but those in tests (a directory component ending in `Tests` or
# `TestSupport`, which may read the log store to check what `KernovaLogger`
# emitted) and in KernovaLogging, which implements `KernovaLogger` over the
# platform. Two findings:
#
# - Emitting through the platform log: `Logger` (`os.Logger`), `os_log…`,
#   `OSLog(`, `NSLog…`, `syslog`, `vsyslog`, `openlog`. Importing `os` is
#   not one — `os_unfair_lock` lives there.
# - Console output: a bare or `Swift.`-qualified `print`, `debugPrint` or
#   `dump`, `FileHandle.standardOutput`/`.standardError`, C's `stdout`,
#   `stderr`, `STDOUT_FILENO`, `STDERR_FILENO`, `printf`, `puts`, `putchar`,
#   `perror`, and `write` or `_write` to descriptor 1 or 2. A command-line
#   mode answers through KernovaConsole's `Console`, the one way to the
#   process's streams, so this finding exempts only KernovaConsole,
#   `kernova-bench` (KernovaBench) and Tools/.
#
# A member call (`view.print(`, `process.standardError = …`) is not matched.

use strict;
use warnings;

my $exempt = qr{
    ^KernovaKit/Sources/KernovaLogging/
  | (?:^|/) [^/]* (?:Tests|TestSupport) /
}x;
my $console_exempt = qr{
    ^Tools/
  | ^KernovaKit/Sources/(?:KernovaBench|KernovaConsole)/
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
  | (?<![\w.]) _?write \s* \( \s* [12] \s* ,
}x;

+{
    pass => 'logging: outside tests, only KernovaLogging emits to the platform log, and beside kernova-bench and Tools/ only Console writes to the console',
    check => sub {
        my ($path, $code) = @_;
        $path =~ s{^\./}{};
        return () if $path =~ $exempt;
        my @found;
        while ($code =~ m{$log_api}g) {
            push @found, [SwiftSource::line_at($code, $-[0]), "the platform log API; log through KernovaLogger.log(_:_:)"];
        }
        if ($path !~ $console_exempt) {
            while ($code =~ m{$console}g) {
                push @found, [SwiftSource::line_at($code, $-[0]), "console output; log through KernovaLogger.log(_:_:), or answer a command line through Console"];
            }
        }
        return @found;
    },
};
