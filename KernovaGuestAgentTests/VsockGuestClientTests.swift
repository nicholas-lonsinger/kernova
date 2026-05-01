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
        ) { _, _ in localFd }
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

        // Return localFd on first call, nil thereafter — prevents reuse of a
        // closed fd if the client retries after the remote closes.
        let callCount = AtomicInt()
        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            callCount.increment() == 1 ? localFd : nil
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
            return localFd
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

        // Await the background work by sleeping; the provider returns localFd
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
        ) { _, _ in localFd }

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
            return nil
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
            return localFd
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

    @Test("socketProvider returning nil triggers retry until a real fd arrives")
    func providerNilTriggersRetry() async throws {
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
            return n < targetAttempt ? nil : localFd
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
}

// MARK: - Concurrency helpers

/// Actor-isolated counter for tracking cross-task call counts.
private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
