import Testing
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport

@Suite("VsockGuestClient connect/retry/stop lifecycle", .admissionGated)
struct VsockGuestClientTests {
    // MARK: - Tests

    @Test("start invokes serve closure with a connected channel")
    func startInvokesServeClosure() async throws {
        let fastRetry: TimeInterval = 0.05
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let (servedStream, continuation) = AsyncStream<Void>.makeStream()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in .success(localFd) }
        defer { client.stop() }

        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        _ = try await awaitFirst(servedStream)
    }

    @Test("liveChannel is non-nil while serve is running and nil after serve returns")
    func liveChannelLifecycle() async throws {
        let fastRetry: TimeInterval = 0.05
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()

        // Return localFd on first call, transient failure thereafter — prevents
        // reuse of a closed fd if the client retries after the remote closes.
        let callCount = AtomicInt()
        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            callCount.increment() == 1 ? .success(localFd) : .failure(.transient("test: no fd"))
        }
        defer { client.stop() }

        let (enteredStream, continuation) = AsyncStream<Void>.makeStream()
        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        _ = try await awaitFirst(enteredStream)

        // RATIONALE: sanctioned no-signal poll (docs/TESTING.md "Async waits in
        // tests") — `liveChannel` is lock-protected SUT state, not @Observable
        // or a test-owned double, so there is no signal to await.
        try await waitUntil { client.liveChannel != nil }
        #expect(client.liveChannel != nil)

        remote.close()
        try await waitUntil { client.liveChannel == nil }
        #expect(client.liveChannel == nil)
    }

    /// Exercises the `connectAndServe` pre-serve abort path: the reconnect
    /// loop is stopped before a connection is established so the `stopped`
    /// guard fires and `serve` is never called.
    @Test("stop while reconnecting aborts loop without calling serve")
    func stopMidConnectAbortBeforeServe() async throws {
        let fastRetry: TimeInterval = 0.05
        let serveCallCount = AtomicInt()
        let providerEnteredGate = DispatchSemaphore(value: 0)
        let providerReleaseGate = DispatchSemaphore(value: 0)

        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            // Provider runs synchronously on the reconnect-loop thread.
            // Signal we've entered, then block until the test releases us.
            providerEnteredGate.signal()
            providerReleaseGate.wait()  // Legal: called synchronously, not from async context
            return .success(localFd)
        }

        client.start { _ in
            serveCallCount.increment()
        }

        // Wait (on a background thread) until the provider is entered, then
        // stop the client, then release the provider. The provider parks its own
        // thread by contract, so this hand-off must not ride the cooperative
        // pool.
        let stopDone = AtomicInt()
        DispatchQueue.global(qos: .userInitiated).async {
            providerEnteredGate.wait()
            client.stop()
            providerReleaseGate.signal()
            stopDone.increment()
        }
        try await stopDone.changed.wait { stopDone.value > 0 }

        // RATIONALE: negative assertion ("prove serve was never invoked") — a
        // fixed observation window, per docs/TESTING.md "Async waits in tests".
        // The provider only returns `.success(localFd)` after the release above,
        // so the window has to span the loop's post-provider `stopped` check.
        // `nanoseconds:`, not `for:` — this target deploys to macOS 12.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(serveCallCount.value == 0)
        #expect(client.liveChannel == nil)
    }

    @Test("stop mid-serve tears down the channel and does not re-invoke serve")
    func stopMidServe() async throws {
        let fastRetry: TimeInterval = 0.05
        let (localFd, remoteFd) = try makeRawSocketPair()
        _ = remoteFd  // keep alive; remote end closed when test exits

        let callCounter = CallCounter()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in .success(localFd) }

        let (enteredStream, continuation) = AsyncStream<Void>.makeStream()

        client.start { channel in
            await callCounter.increment()
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        _ = try await awaitFirst(enteredStream)

        // Stop while serve is in flight
        client.stop()

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await callCounter.value == 1)
        #expect(client.liveChannel == nil)
    }

    @Test("stop before start is a no-op; subsequent start is also a no-op")
    func stopBeforeStartIsNoOp() async throws {
        let fastRetry: TimeInterval = 0.05
        let provideCounter = AtomicInt()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .failure(.transient("test: no fd"))
        }

        client.stop()
        client.start { _ in }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(provideCounter.value == 0)
        #expect(client.liveChannel == nil)
    }

    @Test("start is idempotent — second call before stop is a no-op")
    func startIsIdempotent() async throws {
        let fastRetry: TimeInterval = 0.05
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let provideCounter = AtomicInt()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .success(localFd)
        }
        defer { client.stop() }

        let (enteredStream, continuation) = AsyncStream<Void>.makeStream()
        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        _ = try await awaitFirst(enteredStream)

        // Second start — no-op
        client.start { _ in }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(provideCounter.value == 1)
    }

    @Test(
        "socketProvider returning transient failure triggers retry until a real fd arrives",
        arguments: EngineClockKind.allCases)
    func providerTransientFailureTriggersRetry(kind: EngineClockKind) async throws {
        let fastRetry: TimeInterval = 0.05
        let targetAttempt = 3

        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let attemptCounter = AtomicInt()
        let (servedStream, continuation) = AsyncStream<Void>.makeStream()

        let client = makeTestClient(
            kind: kind,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            let n = attemptCounter.increment()
            return n < targetAttempt ? .failure(.transient("attempt \(n)")) : .success(localFd)
        }
        defer { client.stop() }

        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        _ = try await awaitFirst(servedStream)

        #expect(attemptCounter.value >= targetAttempt)
        #expect(client.liveChannel != nil)
    }

    @Test("permanent socket-provider failure halts the reconnect loop")
    func permanentFailureHaltsLoop() async throws {
        let fastRetry: TimeInterval = 0.05
        let provideCounter = AtomicInt()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .failure(.permanent("AF_VSOCK not supported"))
        }
        defer { client.stop() }

        client.start { _ in }

        // Wait several retry intervals — if the loop kept retrying we'd see >1 calls.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(provideCounter.value == 1)
        #expect(client.liveChannel == nil)
    }

    /// Pins the docstring contract: once permanently terminated, subsequent
    /// `start` calls are no-ops — the client cannot be restarted.
    @Test("start after permanent termination is a no-op — provider is never called again")
    func startAfterPermanentTerminationIsNoOp() async throws {
        let fastRetry: TimeInterval = 0.05
        let provideCounter = AtomicInt()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .failure(.permanent("AF_VSOCK not supported"))
        }

        client.start { _ in }

        // Wait (event-driven) for the provider to be invoked once; the
        // permanent failure terminates the loop, so the count never climbs
        // past 1.
        try await provideCounter.changed.wait { provideCounter.value >= 1 }
        #expect(provideCounter.value == 1)

        // Re-start — must be a no-op because stopped == true.
        client.start { _ in }

        // Wait another retry window; provider count must remain 1.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(provideCounter.value == 1)
        #expect(client.liveChannel == nil)
    }
}

// MARK: - classifySocketErrno tests

@Suite("VsockGuestClient.classifySocketErrno classification", .admissionGated)
struct ClassifySocketErrnoTests {
    @Test("EAFNOSUPPORT classifies as permanent")
    func eafnosupportIsPermanent() {
        let result = VsockGuestClient.classifySocketErrno(EAFNOSUPPORT, label: "test")
        if case .permanent = result {
        } else {
            Issue.record("Expected .permanent for EAFNOSUPPORT, got \(result)")
        }
    }

    @Test("EPROTONOSUPPORT classifies as permanent")
    func eprotonosupportIsPermanent() {
        let result = VsockGuestClient.classifySocketErrno(EPROTONOSUPPORT, label: "test")
        if case .permanent = result {
        } else {
            Issue.record("Expected .permanent for EPROTONOSUPPORT, got \(result)")
        }
    }

    @Test("EMFILE (resource exhaustion) classifies as transient")
    func emfileIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(EMFILE, label: "test")
        if case .transient = result {
        } else {
            Issue.record("Expected .transient for EMFILE, got \(result)")
        }
    }

    @Test("EACCES (access control) classifies as transient — sandbox may clear")
    func eaccesIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(EACCES, label: "test")
        if case .transient = result {
        } else {
            Issue.record("Expected .transient for EACCES, got \(result)")
        }
    }

    @Test("errno 0 (unknown/default) classifies as transient")
    func zeroErrnoIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(0, label: "test")
        if case .transient = result {
        } else {
            Issue.record("Expected .transient for errno=0, got \(result)")
        }
    }

    // MARK: - pause / resume

    @Test(
        "pause() before connect prevents the loop from invoking serve",
        arguments: EngineClockKind.allCases)
    func pauseBeforeStartSuppressesConnect(kind: EngineClockKind) async throws {
        let fastRetry: TimeInterval = 0.02
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let calls = AtomicInt()
        let client = makeTestClient(
            kind: kind,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            _ = calls.increment()
            return .success(localFd)
        }
        defer { client.stop() }

        client.pause()  // pause before start
        client.start { _ in }

        // Give the loop several retry intervals to attempt a connect.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(calls.value == 0, "Paused client should not invoke socketProvider")
    }

    @Test("pause() during in-flight connect aborts the channel before serve runs")
    func pauseDuringInFlightConnectAborts() async throws {
        // Regression for a race: pause() that lands while connectAndServe
        // is mid-call (after socketProvider returned, before the lock-
        // protected currentChannel publish) must NOT result in serve(...)
        // being invoked. The fix is for connectAndServe to re-check `paused`
        // under the lock before publishing the channel.
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let providerSleepMs = 100
        let providerEntered = AtomicInt()

        let client = makeTestClient(
            kind: .monotonic,
            port: 12345,
            label: "test",
            retryInterval: 0.02
        ) { _, _ in
            _ = providerEntered.increment()
            // Block the synchronous provider long enough for the test to
            // call pause() between provider-returns and the lock publish.
            // Thread.sleep is appropriate — the provider is sync and runs
            // on a detached cooperative-pool task.
            Thread.sleep(forTimeInterval: Double(providerSleepMs) / 1000.0)
            return .success(localFd)
        }
        defer { client.stop() }

        let serveCalled = AtomicInt()
        client.start { _ in
            _ = serveCalled.increment()
            // Hold so the test sees the increment if the bug regresses.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Wait for the provider to be entered, then pause while it's mid-sleep.
        // The lock check inside connectAndServe must observe paused=true when
        // the provider returns, and abort the publish.
        try await providerEntered.changed.wait { providerEntered.value >= 1 }
        client.pause()

        // Wait past the provider's sleep so connectAndServe has returned.
        try await Task.sleep(nanoseconds: UInt64(providerSleepMs + 100) * 1_000_000)
        #expect(
            serveCalled.value == 0,
            "serve() must not run when pause() landed during connectAndServe")
    }

    @Test(
        "resume() lets the loop connect after a pre-start pause",
        arguments: EngineClockKind.allCases)
    func resumeAllowsConnectAfterPause(kind: EngineClockKind) async throws {
        let fastRetry: TimeInterval = 0.02
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let calls = AtomicInt()
        let client = makeTestClient(
            kind: kind,
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            _ = calls.increment()
            return .success(localFd)
        }
        defer { client.stop() }

        let (servedStream, continuation) = AsyncStream<Void>.makeStream()
        client.pause()
        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        // Sanity: paused, no connect.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(calls.value == 0)

        // Resume: loop wakes within retryInterval and connects.
        client.resume()
        _ = try await awaitFirst(servedStream)
        #expect(calls.value >= 1)
    }

    /// The interval is far past `testWaitBackstop`, so the connect can only
    /// arrive because `resume()` cut the sleep short — a loop that waits its
    /// interval out fails the test rather than passing slowly.
    @Test(
        "resume() cuts short the sleep a parked loop is in",
        arguments: EngineClockKind.allCases)
    func resumeWakesAParkedLoop(kind: EngineClockKind) async throws {
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let client = makeTestClient(
            kind: kind, port: 12345, label: "test", retryInterval: 600
        ) { _, _ in .success(localFd) }
        defer { client.stop() }

        let (servedStream, continuation) = AsyncStream<Void>.makeStream()
        client.pause()
        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        client.resume()
        _ = try await awaitFirst(servedStream)
    }

    /// A wake dropped on the floor here costs a whole retry interval.
    ///
    /// The ordering a VM resume produces: the host refuses the feature channel
    /// while its control handshake is still in flight, and the policy update
    /// that clears the refusal lands before the loop reaches its next sleep.
    @Test("A resume() landing mid-attempt is what the next park consumes")
    func resumeMidAttemptSkipsTheNextPark() async throws {
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let attempts = AtomicInt()
        let firstAttemptRelease = DispatchSemaphore(value: 0)

        let client = makeTestClient(
            kind: .monotonic, port: 12345, label: "test", retryInterval: 600
        ) { _, _ in
            // The provider runs synchronously on the loop's own task, so the
            // loop is provably mid-attempt — not parked — while it blocks here.
            guard attempts.increment() == 1 else { return .success(localFd) }
            firstAttemptRelease.wait()
            return .failure(.transient("test: first attempt refused"))
        }
        defer { client.stop() }

        let (servedStream, continuation) = AsyncStream<Void>.makeStream()
        client.start { channel in
            continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        // The increment is the provider's first statement and it cannot return
        // until released below, so observing it is observing the loop mid-attempt
        // — no second signal, and no blocking wait on the test's side.
        try await attempts.changed.wait { attempts.value >= 1 }
        client.resume()
        firstAttemptRelease.signal()

        _ = try await awaitFirst(servedStream)
        #expect(attempts.value == 2)
    }
}

@Suite("Bounded blocking connect: socket ownership and the parked-attempt gate", .admissionGated)
struct BlockingConnectTests {
    @Test("A syscall that beats the deadline hands the socket to the waiter")
    func syscallBeatsDeadline() {
        let handoff = BlockingConnectHandoff()

        #expect(handoff.finish(errno: 0))
        #expect(handoff.abandon() == false)
        #expect(handoff.outcome == 0)
    }

    @Test("A syscall that outruns the deadline keeps the socket")
    func syscallOutrunsDeadline() {
        let handoff = BlockingConnectHandoff()

        #expect(handoff.abandon())
        #expect(handoff.outcome == nil)
        #expect(handoff.finish(errno: ECONNREFUSED) == false)
        #expect(handoff.outcome == ECONNREFUSED)
    }

    @Test("A failing syscall reports its errno to a waiter still present")
    func failingSyscallReportsErrno() {
        let handoff = BlockingConnectHandoff()

        #expect(handoff.finish(errno: ECONNREFUSED))
        #expect(handoff.outcome == ECONNREFUSED)
    }

    @Test("Attempts that never park are admitted however many run in a row")
    func gateAdmitsEveryHealthyAttempt() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<(BlockingConnectGate.maxParkedAttempts * 8) {
            #expect(gate.admit("data"))
        }
        #expect(gate.parkedCountForTesting("data") == 0)
    }

    @Test("Concurrent attempts on one label are all admitted while none is parked")
    func gateAdmitsEveryConcurrentHealthyAttempt() async {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)
        let dials = 32
        let winners = CallCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<dials {
                group.addTask {
                    if gate.admit("data") { await winners.increment() }
                }
            }
        }

        #expect(await winners.value == dials)
    }

    @Test("Past the parked cap, admission waits out a doubling backoff")
    func gateBacksOffPastParkedCap() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)

        clock.advance(seconds: BlockingConnectGate.backoffFloor - 1)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: 1)
        #expect(gate.admit("control"))
        gate.markParked("control")

        // One attempt past the cap doubles the wait.
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(gate.admit("control"))
    }

    @Test("The backoff never exceeds its ceiling however many attempts are parked")
    func gateBackoffStopsAtCeiling() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        var backoff = BlockingConnectGate.backoffFloor
        while backoff < BlockingConnectGate.backoffCeiling {
            #expect(gate.admit("control") == false)
            clock.advance(seconds: backoff)
            #expect(gate.admit("control"))
            gate.markParked("control")
            backoff *= 2
        }
        // From here every admission needs exactly the ceiling, never more.
        for _ in 0..<2 {
            clock.advance(seconds: BlockingConnectGate.backoffCeiling - 1)
            #expect(gate.admit("control") == false)
            clock.advance(seconds: 1)
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
    }

    @Test("An attempt completing inside its deadline lifts the rationing")
    func gateHealsOnACompletedAttempt() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)

        gate.markCompleted("control")

        #expect(gate.admit("control"))
        #expect(gate.admit("control"))
        #expect(gate.parkedCountForTesting("control") == BlockingConnectGate.maxParkedAttempts)
    }

    @Test("A park after a heal is rationed from the floor, not the escalated wait")
    func gateRationsAgainFromTheFloorAfterAHeal() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        // Escalate the first wedge well past the floor. Parked attempts are
        // never reclaimed, so their count alone would pin every later wedge at
        // the ceiling.
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) {
            gate.markParked("control")
        }
        gate.markCompleted("control")
        #expect(gate.admit("control"))
        gate.markParked("control")

        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor - 1)
        #expect(gate.admit("control") == false)
        clock.advance(seconds: 1)
        #expect(gate.admit("control"))
    }

    @Test("A parked syscall returning discharges its attempt")
    func gateDischargesAReturnedPark() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)

        gate.markParkReturned("control")

        #expect(gate.parkedCountForTesting("control") == BlockingConnectGate.maxParkedAttempts - 1)
        #expect(gate.admit("control"))
    }

    @Test("Parks whose syscalls returned no longer escalate a later wedge")
    func gateReturnedParksDoNotEscalateTheNextWedge() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        // Strand a tall wedge, then let every parked syscall return — a
        // torn-down transport, not a completion, so no heal fires.
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) {
            gate.markParked("control")
        }
        for _ in 0..<(BlockingConnectGate.maxParkedAttempts + 8) {
            gate.markParkReturned("control")
        }

        // The next wedge is rationed from the floor, not from an exponent
        // counting threads that are no longer stranded.
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)
        clock.advance(seconds: BlockingConnectGate.backoffFloor)
        #expect(gate.admit("control"))
    }

    @Test("A park reverted because the syscall beat the deadline leaves the count unchanged")
    func gateRevertedParkLeavesTheCountUnchanged() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        gate.markParked("control")
        gate.revertPark("control")

        #expect(gate.parkedCountForTesting("control") == BlockingConnectGate.maxParkedAttempts)
        // The reverted attempt completed after all, so nothing is rationed.
        #expect(gate.admit("control"))
    }

    @Test("More discharges than parks never drive the count below zero")
    func gateParkedCountFloorsAtZero() {
        let gate = BlockingConnectGate()

        gate.markParkReturned("control")
        gate.markParked("control")
        gate.markParkReturned("control")
        gate.markParkReturned("control")

        #expect(gate.parkedCountForTesting("control") == 0)
        #expect(gate.admit("control"))
    }

    @Test("Labels carry their parked attempts independently")
    func gateSeparatesLabels() {
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)

        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("control"))
            gate.markParked("control")
        }
        #expect(gate.admit("control") == false)

        #expect(gate.admit("clipboard"))
        #expect(gate.parkedCountForTesting("clipboard") == 0)
    }
}

@Suite("boundedBlockingConnect: outcome arms over real descriptors", .admissionGated)
struct BoundedBlockingConnectTests {
    @Test("A prompt success hands the open fd to the caller and charges the gate nothing")
    func promptSuccessKeepsCallerOwnership() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let gate = BlockingConnectGate()

        let outcome = VsockGuestClient.boundedBlockingConnect(
            fd: fds[0], label: "test", port: 0, gate: gate
        ) { 0 }

        #expect(outcome == .connected)
        #expect(fcntl(fds[0], F_GETFD) >= 0)
        #expect(gate.parkedCountForTesting("test") == 0)
    }

    @Test("A prompt failure reports its errno with the caller still owning the fd")
    func promptFailureReportsErrno() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let gate = BlockingConnectGate()

        let outcome = VsockGuestClient.boundedBlockingConnect(
            fd: fds[0], label: "test", port: 0, gate: gate
        ) { ECONNREFUSED }

        #expect(outcome == .failed(errno: ECONNREFUSED))
        #expect(fcntl(fds[0], F_GETFD) >= 0)
        #expect(gate.parkedCountForTesting("test") == 0)
    }

    @Test("An outrun deadline abandons the worker, which closes the fd when the call returns")
    func deadlineAbandonsWorkerWhichCloses() async throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[1]) }
        let fd = fds[0]
        let gate = BlockingConnectGate()
        let parked = DispatchSemaphore(value: 0)

        let outcome = VsockGuestClient.boundedBlockingConnect(
            fd: fd, label: "test", port: 0, gate: gate, deadline: 0.05
        ) {
            parked.wait()
            return ECONNABORTED
        }

        #expect(outcome == .abandoned)
        #expect(gate.parkedCountForTesting("test") == 1)
        #expect(fcntl(fd, F_GETFD) >= 0)

        // The kernel finally returns; the worker discharges the parked
        // attempt, then closes the fd it now owns.
        parked.signal()
        // RATIONALE: another thread's close(2) emits no signal — genuinely
        // signal-less predicate.
        try await waitUntil { fcntl(fd, F_GETFD) == -1 }
        #expect(gate.parkedCountForTesting("test") == 0)
    }

    @Test("A gate refusal reports busy without running the connect or touching the fd")
    func gateRefusalSkipsTheSocket() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("test"))
            gate.markParked("test")
        }
        let calls = AtomicInt()

        let outcome = VsockGuestClient.boundedBlockingConnect(
            fd: fds[0], label: "test", port: 0, gate: gate
        ) {
            calls.increment()
            return 0
        }

        #expect(outcome == .busy)
        #expect(calls.value == 0)
        #expect(fcntl(fds[0], F_GETFD) >= 0)
    }

    @Test("An attempt that completes lifts the backoff parked attempts imposed")
    func completedAttemptLiftsTheBackoff() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let clock = TestEngineClock()
        let gate = BlockingConnectGate(clock: clock)
        for _ in 0..<BlockingConnectGate.maxParkedAttempts {
            #expect(gate.admit("test"))
            gate.markParked("test")
        }
        clock.advance(seconds: BlockingConnectGate.backoffFloor)

        let outcome = VsockGuestClient.boundedBlockingConnect(
            fd: fds[0], label: "test", port: 0, gate: gate
        ) { ECONNREFUSED }

        // A refusal inside the deadline proves the host answers, so the next
        // attempt waits out no backoff even with the parks still outstanding.
        #expect(outcome == .failed(errno: ECONNREFUSED))
        #expect(gate.parkedCountForTesting("test") == BlockingConnectGate.maxParkedAttempts)
        #expect(gate.admit("test"))
    }
}

// MARK: - awaitConnectCompletion revents classification

@Suite("VsockGuestClient.awaitConnectCompletion revents classification", .admissionGated)
struct AwaitConnectCompletionTests {
    @Test("POLLHUP with SO_ERROR == 0 is a completed connect, not a failure")
    func pollhupWithNoSocketErrorCompletes() throws {
        guard #available(macOS 26.0, *) else { return }
        // A socketpair end whose peer has closed reports POLLHUP from poll()
        // while SO_ERROR reads 0 — the shape a state-blind vsock fd produces
        // for a connect the host accepted
        // (docs/research/2026-08-06-macos13-vsock-nonblocking-state-blind.md).
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        close(fds[1])
        defer { close(fds[0]) }
        #expect(
            VsockGuestClient.awaitConnectCompletion(
                fd: fds[0], label: "test", port: 0, clock: MonotonicEngineClock()))
    }

    @Test("POLLNVAL (invalid descriptor) stays fatal")
    func pollnvalFails() {
        guard #available(macOS 26.0, *) else { return }
        // A number at the fd-table size can never name an open descriptor, so
        // poll() reports POLLNVAL with no fd-reuse window.
        let fd = getdtablesize()
        #expect(
            !VsockGuestClient.awaitConnectCompletion(
                fd: fd, label: "test", port: 0, clock: MonotonicEngineClock()))
    }
}

// MARK: - Concurrency helpers

/// Actor-isolated counter for tracking cross-task call counts.
private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
