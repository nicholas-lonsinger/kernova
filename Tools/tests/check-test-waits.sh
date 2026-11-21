#!/usr/bin/env bash
# Fixture tests for the test-waits rule (Tools/swift-rules/test-waits.pm):
# which real-clock sleeps and wait deadlines it flags, on which line, and which
# files it scans.
#
# fixture reads: Tools/swift-rules/test-waits.pm Tools/check-swift-sources.sh Tools/lib/output.sh
# fixture reads: Tools/install-dead-code-tool.sh Tools/lib/tool-cache.sh Tools/lib/dead-code-tool.sh
# fixture reads: Tools/lib/package-pins.sh Tools/DeadCode

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/dead-code-tool.sh
. "$ROOT/Tools/lib/dead-code-tool.sh"
dead_code_sources=$(fixture_dead_code_sources) || exit 1
run_rule() { bash "$ROOT/Tools/check-swift-sources.sh" --tool "$dead_code_sources" --rule test-waits "$@"; }

if [ -t 1 ]; then c_red=$'\033[0;31m'; c_reset=$'\033[0m'; else c_red=''; c_reset=''; fi
FAIL=0
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=../lib/git-isolation.sh
. "$ROOT/Tools/lib/git-isolation.sh"
isolate_git "$tmp"

# expect <name> <want> <swift source> — the check, run over a file holding the
# source, reports exactly the lines in <want> (space-separated, empty for a
# pass).
expect() {
    local name=$1 want=$2 file="$tmp/$1.swift" output status got
    printf '%s\n' "$3" >"$file"
    output=$(run_rule "$file" 2>&1)
    status=$?
    got=$(printf '%s\n' "$output" | sed -n "s|^check-test-waits: $file:\([0-9]*\) .*|\1|p" | tr '\n' ' ')
    got=${got% }
    if [ "$got" != "$want" ]; then
        fail "$name: flagged lines '$got', wanted '$want'"
    elif [ -n "$want" ] && [ "$status" -eq 0 ]; then
        fail "$name: flagged but exited 0"
    elif [ -z "$want" ] && [ "$status" -ne 0 ]; then
        fail "$name: flagged nothing but exited $status"
    fi
}

# Raw real-clock sleeps.

expect task-sleep 2 'let x = 1
try await Task.sleep(for: .milliseconds(200))'

expect task-sleep-nanoseconds 1 'try await Task.sleep(nanoseconds: 300_000_000)'

expect task-sleep-generic 1 'try await Task<Never, Never>.sleep(for: .seconds(1))'

expect task-sleep-across-lines 1 'try await Task
    .sleep(for: interval)'

expect thread-sleep 1 'Thread.sleep(forTimeInterval: 0.1)'

expect posix-sleeps '1 2 3 4' 'sleep(1)
usleep(1_000)
nanosleep(&request, nil)
Darwin.sleep(1)'

expect async-after 1 'DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done = true }'

expect inline-real-clocks '1 2 3 4 5 6' 'try await MonotonicEngineClock().sleep(for: 0.2)
try await ContinuousEngineClock().sleep(for: window)
try await ContinuousClock().sleep(for: .seconds(1))
try await SuspendingClock().sleep(for: .seconds(1))
try await ContinuousClock.continuous.sleep(for: .seconds(1))
try await SuspendingClock.suspending.sleep(for: .seconds(1))'

expect named-clock '' 'let clock = TestEngineClock()
try await clock.sleep(for: 3600)
try await self.clock.sleep(for: 1)'

expect clock-as-default-argument '' 'func makeAgent(clock: any EngineClock = MonotonicEngineClock()) {}'

expect member-sleep '' 'try await recorder.sleep(for: 1)
self.sleep(1)'

expect local-sleep-function '' 'private func sleep(_ coordinator: Coordinator) async {}
await sleep(coordinator)'

expect qualified-beside-local-function 2 'private func sleep(_ coordinator: Coordinator) async {}
Darwin.sleep(1)'

expect sleep-inside-identifiers '' 'let asleep = coordinator.sleepWake(isAsleep(x))
taskSleep(1)'

expect comment '' '// Task.sleep(for: .seconds(1)) would race the work.
/* Thread.sleep(forTimeInterval: 1) */
let x = 1'

expect string '' 'let s = "Thread.sleep(forTimeInterval: 1) and usleep(5)"'

expect marker-does-not-exempt-a-sleep 2 '// deadline-under-test - the sleep is the point
try await Task.sleep(for: .seconds(1))'

# Numbers in a wait's timeout.

expect gate-literal 1 'try await gate.wait(timeout: 2) { done }'

expect semaphore-literal 1 '_ = blocked.wait(timeout: .now() + 2)'

expect duration-literal 1 'try await waitUntil(timeout: .seconds(2)) { done }'

expect fraction-literal 1 'try await recorder.waitForFrameCount(3, timeout: 0.5)'

expect fulfillment-literal 1 'await fulfillment(of: [expectation], timeout: 1)'

expect timeout-on-later-line 3 'try await recorder.waitForFrameCount(
    3,
    timeout: 0.5)'

expect backstop '' '_ = blocked.wait(timeout: .now() + testWaitBackstop)
try await gate.wait(timeout: testWaitBackstop) { done }'

expect default-timeout '' 'try await gate.wait { done }
try await waitForChange { model.ready }'

expect named-timeout '' 'try await waitForChange(timeout: timeout) { done }
_ = blocked.wait(timeout: .now() + limit2)
_ = blocked.wait(timeout: .now() + Self.v1Limit)'

expect subject-timeout '' 'try await core.restart(vm, timeout: 1, consent: .none)
let outcome = await runPull(coordinator, transferID: 5, timeout: 0.12)'

expect timeout-of-a-call-nested-in-a-wait '' 'try await gate.wait(until: { restart(timeout: 1) })'

expect marker-on-line '' '_ = blocked.wait(timeout: .now() + 1)  // deadline-under-test - expiry is the asserted outcome'

expect marker-above '' '// deadline-under-test - expiry is the asserted outcome
_ = blocked.wait(timeout: .now() + 1)'

expect marker-above-timeout-argument '' 'try await recorder.waitForFrameCount(
    3,
    // deadline-under-test - expiry is the asserted outcome
    timeout: 0.5)'

expect marker-without-reason 2 '// deadline-under-test
_ = blocked.wait(timeout: .now() + 1)'

expect marker-two-lines-above 3 '// deadline-under-test - too far away
let x = 1
_ = blocked.wait(timeout: .now() + 1)'

# Waits with no deadline.

expect raw-continuations '1 2 3 4' 'await withCheckedContinuation { c in queue.async { c.resume() } }
let value = try await withCheckedThrowingContinuation { c in start(c) }
await withUnsafeContinuation { _ in }
try await withUnsafeThrowingContinuation { c in start(c) }'

expect backstop-park '' 'try await Backstop("close").park { resume in runtime.close { resume(()) } }'

expect detached-tasks '1 2' 'let paste = Task.detached { pasteboard.invokeProvider(forType: type) }
let served = await Task
    .detached { exchange.content(id) }.value'

expect other-tasks '' 'let task = Task { await work() }
let call = BlockingCall { pasteboard.invokeProvider(forType: type) }
let pasted = try await offCooperativePool { pasteboard.invokeProvider(forType: type) }'

expect blocking-waits '1 2 3 4 6' 'semaphore.wait()
hold?.wait()
gates[lane + 1].wait()
self.condition.wait( )
_ = group
    .wait()'

expect forever-waits '1 2 3' '_ = semaphore.wait(timeout: .distantFuture)
_ = group.wait(timeout: DispatchTime.distantFuture)
_ = semaphore.wait(wallTimeout: .distantFuture)'

expect child-process-waits '1 2 3 5' 'process.waitUntilExit()
let data = output.fileHandleForReading.readDataToEndOfFile()
let rest = try errors.fileHandleForReading.readToEnd()
codesign
    .waitUntilExit()'

expect child-process '' 'let ran = try ChildProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", command]).exit()
let chunk = try handle.read(upToCount: 4_096)'

expect awaited-waits '' 'await readiness.wait()
try await gate.wait()
let ready = LibraryReadiness(awaitReady: { await read.wait() })
_ = await self.parked[0].wait()'

expect waits-with-arguments '' 'try Backstop("the release").wait(for: release)
_ = blocked.wait(timeout: .now() + testWaitBackstop)
try await gate.wait { done }'

expect unbounded-in-prose '' '// semaphore.wait() and Task.detached would park with no deadline.
let s = "withCheckedContinuation { c in c.resume() }"'

expect marker-does-not-exempt-an-unbounded-wait 2 '// deadline-under-test - the wait is the point
semaphore.wait()'

expect backstop-literal 1 'let backstop = Backstop("the call", timeout: 0.1)'

expect backstop-literal-marked '' '// deadline-under-test - the backstop firing is the asserted outcome
let backstop = Backstop("the call", timeout: 0.1)'

expect backstop-default '' 'let backstop = Backstop("the call")
let named = Backstop("the call", timeout: limit)'

# A file the check cannot open fails it, rather than passing unread.
output=$(run_rule "$tmp/missing.swift" 2>&1)
status=$?
if [ "$status" -eq 0 ]; then
    fail "unreadable-file: exited 0 for a file it could not open"
elif ! printf '%s\n' "$output" | grep -q "cannot read $tmp/missing.swift"; then
    fail "unreadable-file: no 'cannot read' line in: $output"
fi

# With no arguments it scans the tracked files under a test target, a
# `Support/` folder included, and nothing under a test-support module or
# outside a test target.
mkdir -p "$tmp/repo/AppTests/Support" "$tmp/repo/AppTestSupport" "$tmp/repo/App"
git init -q "$tmp/repo"
for file in AppTests/Case.swift AppTests/Support/Helper.swift AppTestSupport/Waits.swift App/Main.swift; do
    printf '%s\n' 'try await Task.sleep(for: .seconds(1))' >"$tmp/repo/$file"
done
git -C "$tmp/repo" add .
output=$(cd "$tmp/repo/App" && run_rule 2>&1)
status=$?
got=$(printf '%s\n' "$output" | sed -n 's|^check-test-waits: \([^ ]*\) .*|\1|p' | sort | tr '\n' ' ')
if [ "$status" -eq 0 ] || [ "$got" != 'AppTests/Case.swift:1 AppTests/Support/Helper.swift:1 ' ]; then
    fail "default-scope: wanted the two AppTests files flagged, got status $status: $output"
fi

# A relative argument names a file under the caller's working directory.
output=$(cd "$tmp/repo/AppTests" && run_rule Case.swift 2>&1)
status=$?
if [ "$status" -eq 0 ] || ! printf '%s\n' "$output" | grep -q '^check-test-waits: Case.swift:1 '; then
    fail "relative-path: wanted Case.swift:1 flagged, got status $status: $output"
fi

if [ "$FAIL" -gt 0 ]; then
    printf 'check-test-waits fixtures: %d failed\n' "$FAIL" >&2
    exit 1
fi
printf 'check-test-waits fixtures: all passed\n'
