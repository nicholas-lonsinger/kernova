#!/usr/bin/env bash
# Fixture tests for Tools/check-logging.sh: which platform-log and console
# calls it flags, on which line, and which paths each finding covers.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_script="$ROOT/Tools/check-logging.sh"

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

app='KernovaCore/Sources/KernovaCore/Fixture.swift'
agent_runtime='KernovaKit/Sources/KernovaAgentRuntime/Fixture.swift'
cli='KernovaCLI/Fixture.swift'
cli_core='KernovaKit/Sources/KernovaCLICore/Fixture.swift'
linux_agent='KernovaKit/Sources/KernovaLinuxAgent/Fixture.swift'
darwin_agent='KernovaKit/Sources/KernovaPlatformDarwin/Fixture.swift'
mac_agent='KernovaMacOSAgent/Fixture.swift'
console='KernovaKit/Sources/KernovaConsole/Fixture.swift'
bench='KernovaKit/Sources/KernovaBench/Fixture.swift'
logging='KernovaKit/Sources/KernovaLogging/Fixture.swift'
test_file='KernovaKit/Tests/KernovaPortableTests/Fixture.swift'
test_support='KernovaKit/Sources/KernovaTestSupport/Fixture.swift'
tool='Tools/DeadCode/Sources/dead-code/main.swift'

# expect <name> <path> <want> <swift source> — the check, run over a file at
# <path> relative to a scratch repository root holding the source, flags
# exactly the lines in <want> (space-separated, empty for a pass).
expect() {
    local name=$1 path=$2 want=$3 dir="$tmp/$1" output status got
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$4" >"$dir/$path"
    output=$(cd "$dir" && bash "$check_script" "$path" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-logging: $path:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

# The platform log.

expect os-logger "$app" '1 2' 'let a = os.Logger(subsystem: "s", category: "c")
let b: Logger = .init(subsystem: "s", category: "c")'
expect os-log "$app" '1 2' 'os_log("x")
os_log(.error, log: log, "x")'
expect os-log-handle "$app" '1' 'let log = OSLog(subsystem: "s", category: "c")'
expect ns-log "$app" '1 2' 'NSLog("x")
NSLogv(format, args)'
expect syslog "$agent_runtime" '1 2' 'openlog("kernova", 0, 0)
syslog(LOG_ERR, "x")'

expect kernova-logger "$app" '' 'private static let logger = KernovaLogger(subsystem: "s", category: "c")
logger.log(.notice, "Started")'
expect os-import-for-a-lock "$app" '' 'import os
let lock = os_unfair_lock()'
expect prose-and-strings "$app" '' '// Never NSLog or print here; os.Logger skips the host.
let text = "print(x) and os_log and Logger("
/* debugPrint(x) */'

# Console output.

expect prints "$app" '1 2 3 4' 'print("x")
Swift.print("x")
debugPrint(value)
dump(value)'
expect standard-handles "$agent_runtime" '1 2' 'FileHandle.standardError.write(data)
FileHandle.standardOutput.write(data)'
expect c-streams "$agent_runtime" '1 2 3 4 5 6' 'fputs("x", stderr)
_ = write(STDERR_FILENO, buffer, count)
printf("x")
perror("x")
_ = write(1, buffer, count)
_ = _write(2, buffer, count)'
expect member-calls "$app" '' 'view.print(sender)
process.standardError = pipe
printer.dump(tree)
self.puts(x)
socket.write(2, buffer)
_ = write(fd, buffer, 12)'

# Scope.

expect console-may-write "$console" '' 'print("x")
_ = write(STDERR_FILENO, buffer, count)'
expect console-may-not-log "$console" '1' 'NSLog("x")'
expect bench-may-print "$bench" '' 'print("x")'
expect tools-may-print "$tool" '' 'print("x")'
expect cli-may-not-print "$cli" '1' 'print("x")'
expect cli-core-may-not-print "$cli_core" '1 2' 'print("x")
FileHandle.standardError.write(data)'
expect linux-agent-may-not-print "$linux_agent" '1 2' 'print("x")
_ = write(2, buffer, count)'
expect darwin-agent-may-not-print "$darwin_agent" '1' 'print("x")'
expect agent-app-may-not-print "$mac_agent" '1' 'FileHandle.standardError.write(data)'
expect logging-module "$logging" '' 'let logger = os.Logger(subsystem: "s", category: "c")
FileHandle.standardError.write(data)'
expect tests-read-the-log "$test_file" '' 'let log = OSLog(subsystem: "s", category: "c")
print("x")'
expect test-support "$test_support" '' 'print("x")'

# An unreadable file fails.

output=$(cd "$tmp" && bash "$check_script" "$app" 2>&1)
status=$?
if [ "$status" -eq 0 ] || [[ $output != *"cannot read $app"* ]]; then
    fail "missing-file: exited $status without naming the unread file"
fi

if [ "$FAIL" -gt 0 ]; then
    printf '%d check-logging fixture(s) failed\n' "$FAIL"
    exit 1
fi
printf 'check-logging fixtures: all passed\n'
