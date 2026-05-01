import Testing
import Foundation
import Darwin
import KernovaProtocol

@Suite("VsockGuestClient connect/retry/stop lifecycle")
struct VsockGuestClientTests {

    // MARK: - Helpers

    private struct TestFailure: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    /// Creates a connected socketpair; returns (local fd, remote VsockChannel).
    /// The caller owns the remote channel and must close it when done.
    private func makeSocketPair() throws -> (localFd: Int32, remoteChannel: VsockChannel) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let remote = VsockChannel(fileDescriptor: fds[1])
        remote.start()
        return (fds[0], remote)
    }

    /// Waits until the predicate is true or a deadline elapses.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !predicate() {
            throw TestFailure("Predicate did not become true within \(timeout)")
        }
    }

    // MARK: - Tests

    @Test("start invokes serve closure with a connected channel")
    func startInvokesServeClosure() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remote) = try makeSocketPair()
        defer { remote.close() }

        let servedStream = AsyncStream<Void>.makeStream()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in localFd }
        defer { client.stop() }

        client.start { channel in
            servedStream.continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        // Drain the stream with a timeout task
        let serveTask = Task { () -> Void in
            var iterator = servedStream.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(2))
            serveTask.cancel()
        }
        await serveTask.value
        timeoutTask.cancel()
        #expect(!serveTask.isCancelled, "serve closure should have been called")
    }

    @Test("liveChannel is non-nil while serve is running and nil after serve returns")
    func liveChannelLifecycle() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remote) = try makeSocketPair()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in localFd }
        defer { client.stop() }

        let enteredStream = AsyncStream<Void>.makeStream()

        client.start { channel in
            enteredStream.continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        let waitTask = Task { () -> Void in
            var iterator = enteredStream.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        await waitTask.value

        // liveChannel must be non-nil while serve is blocked
        try await waitUntil { client.liveChannel != nil }
        #expect(client.liveChannel != nil)

        // Close the remote end — serve returns — liveChannel should clear
        remote.close()
        try await waitUntil { client.liveChannel == nil }
        #expect(client.liveChannel == nil)
    }

    @Test("stop mid-serve tears down the channel and does not re-invoke serve")
    func stopMidServe() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, _) = try makeSocketPair()

        let callCounter = CallCounter()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in localFd }

        let enteredStream = AsyncStream<Void>.makeStream()

        client.start { channel in
            await callCounter.increment()
            enteredStream.continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        let waitTask = Task { () -> Void in
            var iterator = enteredStream.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        await waitTask.value

        // Stop while serve is in flight
        client.stop()

        // Give a moment for any spurious reconnect
        try await Task.sleep(for: .milliseconds(150))

        let finalCallCount = await callCounter.value
        // After stop the reconnect loop is cancelled; serve should not
        // be invoked again even with the fast retry interval.
        #expect(finalCallCount == 1)
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

        // Stop before start — should not crash or lock
        client.stop()

        // Start after stop — documented as a no-op (cannot be restarted)
        client.start { _ in }

        // Wait briefly to confirm no provider calls were made
        try await Task.sleep(for: .milliseconds(100))
        #expect(provideCounter.value == 0)
        #expect(client.liveChannel == nil)
    }

    @Test("start is idempotent — second call before stop is a no-op")
    func startIsIdempotent() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let (localFd, remote) = try makeSocketPair()
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

        let enteredStream = AsyncStream<Void>.makeStream()
        client.start { channel in
            enteredStream.continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        let waitTask = Task { () -> Void in
            var iterator = enteredStream.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        await waitTask.value

        // Second start — should be a no-op, no new task spawned
        client.start { _ in }

        try await Task.sleep(for: .milliseconds(100))
        // Provider still called exactly once
        #expect(provideCounter.value == 1)
    }

    @Test("socketProvider returning nil triggers retry until a real fd arrives")
    func providerNilTriggersRetry() async throws {
        let fastRetry: Duration = .milliseconds(50)
        let targetAttempt = 3

        let (localFd, remote) = try makeSocketPair()
        defer { remote.close() }

        let attemptCounter = AtomicInt()
        let servedStream = AsyncStream<Void>.makeStream()

        let client = VsockGuestClient(
            port: 12345,
            label: "test",
            retryInterval: fastRetry
        ) { _, _ in
            let n = attemptCounter.increment()
            if n < targetAttempt {
                return nil
            }
            return localFd
        }
        defer { client.stop() }

        client.start { channel in
            servedStream.continuation.yield(())
            do { for try await _ in channel.incoming {} } catch {}
        }

        let serveTask = Task { () -> Void in
            var iterator = servedStream.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(3))
            serveTask.cancel()
        }
        await serveTask.value
        timeoutTask.cancel()

        #expect(!serveTask.isCancelled, "serve should have been called after retries")
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

/// Lock-protected integer for use in non-async closures (socket providers).
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }

    var value: Int {
        lock.withLock { _value }
    }
}
