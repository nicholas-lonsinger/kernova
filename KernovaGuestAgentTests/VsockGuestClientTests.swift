import Testing
import Foundation
import Darwin
import KernovaProtocol

@Suite("VsockGuestClient connect/retry/stop lifecycle")
struct VsockGuestClientTests {

    // MARK: - Tests

    @Test("start invokes serve closure with a connected channel")
    func startInvokesServeClosure() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let (servedStream, continuation) = AsyncStream<Void>.makeStream()

        let client = VsockGuestClient(
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
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()

        // Return localFd on first call, transient failure thereafter — prevents
        // reuse of a closed fd if the client retries after the remote closes.
        let callCount = AtomicInt()
        let client = VsockGuestClient(
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
        let fastRetry: Duration = .milliseconds(50)
        let serveCallCount = AtomicInt()
        let providerEnteredGate = DispatchSemaphore(value: 0)
        let providerReleaseGate = DispatchSemaphore(value: 0)

        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let client = VsockGuestClient(
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
        // stop the client, then release the provider. We must not block the
        // cooperative pool here, so bridge via a detached thread.
        let stopDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            providerEnteredGate.wait()
            client.stop()
            providerReleaseGate.signal()
            stopDone.signal()
        }

        // Await the background work by sleeping; the provider returns .success(localFd)
        // but aborted==true so serve is not invoked.
        try await Task.sleep(for: .milliseconds(300))

        #expect(serveCallCount.value == 0)
        #expect(client.liveChannel == nil)
    }

    @Test("stop mid-serve tears down the channel and does not re-invoke serve")
    func stopMidServe() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remoteFd) = try makeRawSocketPair()
        _ = remoteFd  // keep alive; remote end closed when test exits

        let callCounter = CallCounter()

        let client = VsockGuestClient(
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

        try await Task.sleep(for: .milliseconds(150))
        #expect(await callCounter.value == 1)
        #expect(client.liveChannel == nil)
    }

    @Test("stop before start is a no-op; subsequent start is also a no-op")
    func stopBeforeStartIsNoOp() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let provideCounter = AtomicInt()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .failure(.transient("test: no fd"))
        }

        client.stop()
        client.start { _ in }

        try await Task.sleep(for: .milliseconds(100))
        #expect(provideCounter.value == 0)
        #expect(client.liveChannel == nil)
    }

    @Test("start is idempotent — second call before stop is a no-op")
    func startIsIdempotent() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let provideCounter = AtomicInt()

        let client = VsockGuestClient(
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

        try await Task.sleep(for: .milliseconds(100))
        #expect(provideCounter.value == 1)
    }

    @Test("socketProvider returning transient failure triggers retry until a real fd arrives")
    func providerTransientFailureTriggersRetry() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let targetAttempt = 3

        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let attemptCounter = AtomicInt()
        let (servedStream, continuation) = AsyncStream<Void>.makeStream()

        let client = VsockGuestClient(
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

        _ = try await awaitFirst(servedStream, timeout: .seconds(3))

        #expect(attemptCounter.value >= targetAttempt)
        #expect(client.liveChannel != nil)
    }

    @Test("permanent socket-provider failure halts the reconnect loop")
    func permanentFailureHaltsLoop() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let provideCounter = AtomicInt()

        let client = VsockGuestClient(
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
        try await Task.sleep(for: .milliseconds(300))

        #expect(provideCounter.value == 1)
        #expect(client.liveChannel == nil)
    }

    /// Pins the docstring contract: once permanently terminated, subsequent
    /// `start` calls are no-ops — the client cannot be restarted.
    @Test("start after permanent termination is a no-op — provider is never called again")
    func startAfterPermanentTerminationIsNoOp() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let provideCounter = AtomicInt()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            provideCounter.increment()
            return .failure(.permanent("AF_VSOCK not supported"))
        }

        client.start { _ in }

        // Wait for the loop to reach terminal state.
        try await Task.sleep(for: .milliseconds(300))
        #expect(provideCounter.value == 1)

        // Re-start — must be a no-op because stopped == true.
        client.start { _ in }

        // Wait another retry window; provider count must remain 1.
        try await Task.sleep(for: .milliseconds(300))
        #expect(provideCounter.value == 1)
        #expect(client.liveChannel == nil)
    }
}

// MARK: - classifySocketErrno tests

@Suite("VsockGuestClient.classifySocketErrno classification")
struct ClassifySocketErrnoTests {

    @Test("EAFNOSUPPORT classifies as permanent")
    func eafnosupportIsPermanent() {
        let result = VsockGuestClient.classifySocketErrno(EAFNOSUPPORT, label: "test")
        if case .permanent = result { } else {
            Issue.record("Expected .permanent for EAFNOSUPPORT, got \(result)")
        }
    }

    @Test("EPROTONOSUPPORT classifies as permanent")
    func eprotonosupportIsPermanent() {
        let result = VsockGuestClient.classifySocketErrno(EPROTONOSUPPORT, label: "test")
        if case .permanent = result { } else {
            Issue.record("Expected .permanent for EPROTONOSUPPORT, got \(result)")
        }
    }

    @Test("EMFILE (resource exhaustion) classifies as transient")
    func emfileIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(EMFILE, label: "test")
        if case .transient = result { } else {
            Issue.record("Expected .transient for EMFILE, got \(result)")
        }
    }

    @Test("EACCES (access control) classifies as transient — sandbox may clear")
    func eaccesIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(EACCES, label: "test")
        if case .transient = result { } else {
            Issue.record("Expected .transient for EACCES, got \(result)")
        }
    }

    @Test("errno 0 (unknown/default) classifies as transient")
    func zeroErrnoIsTransient() {
        let result = VsockGuestClient.classifySocketErrno(0, label: "test")
        if case .transient = result { } else {
            Issue.record("Expected .transient for errno=0, got \(result)")
        }
    }

    // MARK: - pause / resume

    @Test("pause() before connect prevents the loop from invoking serve")
    func pauseBeforeStartSuppressesConnect() async throws {
        let fastRetry: Duration = .milliseconds(20)
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let calls = AtomicInt()
        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            _ = calls.increment()
            return .success(localFd)
        }
        defer { client.stop() }

        client.pause() // pause before start
        client.start { _ in }

        // Give the loop several retry intervals to attempt a connect.
        try await Task.sleep(for: .milliseconds(150))
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

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: .milliseconds(20)
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
            try? await Task.sleep(for: .seconds(1))
        }

        // Wait for the provider to be entered, then pause while it's mid-sleep.
        // The lock check inside connectAndServe must observe paused=true when
        // the provider returns, and abort the publish.
        try await waitUntil { providerEntered.value >= 1 }
        client.pause()

        // Wait past the provider's sleep so connectAndServe has returned.
        try await Task.sleep(for: .milliseconds(providerSleepMs + 100))
        #expect(serveCalled.value == 0,
                "serve() must not run when pause() landed during connectAndServe")
    }

    @Test("resume() lets the loop connect after a pre-start pause")
    func resumeAllowsConnectAfterPause() async throws {
        let fastRetry: Duration = .milliseconds(20)
        let (localFd, remoteFd) = try makeRawSocketPair()
        let remote = VsockChannel(fileDescriptor: remoteFd)
        remote.start()
        defer { remote.close() }

        let calls = AtomicInt()
        let client = VsockGuestClient(
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 0)

        // Resume: loop wakes within retryInterval and connects.
        client.resume()
        _ = try await awaitFirst(servedStream)
        #expect(calls.value >= 1)
    }
}

// MARK: - Concurrency helpers

/// Actor-isolated counter for tracking cross-task call counts.
private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
