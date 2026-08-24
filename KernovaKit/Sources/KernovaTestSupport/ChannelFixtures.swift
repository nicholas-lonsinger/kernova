import Darwin
import Foundation
import KernovaKit

// MARK: - Socket / channel factories

/// A connected AF_UNIX socketpair as two raw file descriptors.
public func makeRawSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return (fds[0], fds[1])
}

/// Two started `VsockChannel`s connected by a socketpair.
public func makeStartedChannelPair() throws -> (a: VsockChannel, b: VsockChannel) {
    let (fd0, fd1) = try makeRawSocketPair()
    let a = VsockChannel(fileDescriptor: fd0)
    let b = VsockChannel(fileDescriptor: fd1)
    a.start()
    b.start()
    return (a, b)
}

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within the
///   `testWaitBackstop` deadline.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable.
///   Conflating them once masked a CI flake as a peer-disconnect bug.
///
/// Single-consumer: `AsyncThrowingStream` allows one iteration, so a test that
/// also needs "prove nothing arrived" against the same channel uses
/// ``FrameRecorder`` instead of mixing the two.
public func nextFrame(from channel: VsockChannel) async throws -> Frame {
    let timeout = testWaitBackstop
    let stopwatch = BackstopStopwatch()
    let receiver = Task<Frame?, Error> {
        var iterator = channel.incoming.makeAsyncIterator()
        return try await iterator.next()
    }
    let timeoutTask = Task<Void, Never> {
        try? await MonotonicEngineClock().sleep(for: timeout)
        receiver.cancel()
    }
    defer { timeoutTask.cancel() }

    do {
        guard let frame = try await receiver.value else {
            // Cancelling the task suspended in `AsyncThrowingStream.next()`
            // makes it return nil rather than throw, so the timeout lands here
            // too, distinguishable from a genuine EOF only by the clock.
            if stopwatch.elapsed >= timeout {
                throw TestFailure.backstop(
                    "Timed out waiting for a frame after \(timeout) s",
                    stopwatch: stopwatch, timeout: timeout)
            }
            throw TestFailure("Channel finished without producing a frame (EOF)")
        }
        return frame
    } catch is CancellationError {
        throw TestFailure.backstop(
            "Timed out waiting for a frame after \(timeout) s",
            stopwatch: stopwatch, timeout: timeout)
    }
}

// MARK: - FrameRecorder

/// Buffers everything one channel delivers, from a single consumer.
///
/// `AsyncThrowingStream` is single-consumer and cancelling one iterator ends the
/// shared iteration, so a test needing both "expect this frame" and "expect no
/// frame" against the same channel records once here rather than hand-rolling an
/// iterator per assertion.
public final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [Frame] = []
    private var ended = false
    private var consumeTask: Task<Void, Never>?

    /// Fires on every recorded frame and once the channel ends; await it instead
    /// of polling ``frames``.
    public let recorded = AsyncGate()

    /// Starts recording `channel`.
    public init(channel: VsockChannel) {
        consumeTask = Task { [weak self] in
            do {
                for try await frame in channel.incoming {
                    guard let self else { return }
                    self.lock.withLock { self.storedFrames.append(frame) }
                    self.recorded.notify()
                }
            } catch {
                // The stream errored — recording stops, and `isFinished` says so.
            }
            guard let self else { return }
            self.lock.withLock { self.ended = true }
            self.recorded.notify()
        }
    }

    deinit { consumeTask?.cancel() }

    /// Stops recording.
    public func cancel() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Every frame recorded so far, in arrival order.
    public var frames: [Frame] { lock.withLock { storedFrames } }

    /// How many frames have been recorded.
    public var count: Int { lock.withLock { storedFrames.count } }

    /// Whether the channel has ended — the peer closed its end, or the stream
    /// errored.
    public var isFinished: Bool { lock.withLock { ended } }

    /// The first recorded frame whose payload matches `predicate`, if any.
    public func first(where predicate: (Frame) -> Bool) -> Frame? {
        frames.first(where: predicate)
    }

    /// Every recorded `ClipboardRequest`, in arrival order.
    public var requests: [Kernova_V1_ClipboardRequest] {
        frames.compactMap {
            guard case .clipboardRequest(let request) = $0.payload else { return nil }
            return request
        }
    }

    /// Every recorded `ClipboardOffer`, in arrival order.
    public var offers: [Kernova_V1_ClipboardOffer] {
        frames.compactMap {
            guard case .clipboardOffer(let offer) = $0.payload else { return nil }
            return offer
        }
    }

    /// Every recorded `Heartbeat`, in arrival order.
    public var heartbeats: [Kernova_V1_Heartbeat] {
        frames.compactMap {
            guard case .heartbeat(let heartbeat) = $0.payload else { return nil }
            return heartbeat
        }
    }

    /// Every recorded `Error`, in arrival order.
    public var errors: [Kernova_V1_Error] {
        frames.compactMap {
            guard case .error(let error) = $0.payload else { return nil }
            return error
        }
    }

    // MARK: - Waiting

    /// Suspends until at least `expected` frames have been recorded.
    ///
    /// `>=` rather than `==`: a burst could carry the count past an equality
    /// check between observations and hang the wait to its backstop; a test
    /// asserting an exact count does so separately.
    public func waitForFrameCount(
        _ expected: Int, timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await recorded.wait(timeout: timeout, isolation: isolation) { self.count >= expected }
    }

    /// Suspends until `predicate` holds over the frames recorded so far.
    public func waitForFrames(
        timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        where predicate: () -> Bool
    ) async throws {
        try await recorded.wait(timeout: timeout, isolation: isolation, until: predicate)
    }

    /// Suspends until the channel ends.
    public func waitUntilFinished(
        timeout: TimeInterval = testWaitBackstop, isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await recorded.wait(timeout: timeout, isolation: isolation) { self.isFinished }
    }

    /// Observes for `duration` and throws when any frame arrived past
    /// `sinceCount`.
    ///
    /// A negative assertion has no signal to await, so it takes a fixed
    /// observation window rather than a wait timeout (docs/TESTING.md).
    public func expectNoNewFrames(
        sinceCount before: Int, for duration: TimeInterval = 0.15
    ) async throws {
        try await MonotonicEngineClock().sleep(for: duration)
        let recorded = frames
        guard recorded.count == before else {
            let extras = Array(recorded[min(before, recorded.count)...])
            throw TestFailure(
                "Expected no new frames over \(duration) s; got \(extras.count): "
                    + extras.map { String(describing: $0.payload) }.joined(separator: ", "))
        }
    }
}
