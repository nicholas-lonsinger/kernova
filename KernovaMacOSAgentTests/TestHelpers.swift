import Foundation
import KernovaKit
import KernovaTestSupport

// Bundle-specific test helpers for KernovaMacOSAgentTests. The event-driven/
// poll wait primitives (`AsyncGate`, `waitUntil`, `TestFailure`) and the
// blocking-bridge GCD hop (`offCooperativePool`) live in the shared
// `KernovaTestSupport` package product — see its doc comments.

// MARK: - awaitFirst

/// Awaits the first value emitted by `stream`, with the `testWaitBackstop`
/// deadline.
///
/// - Throws: `TestFailure("Timed out…")` if no value arrives in time.
/// - Throws: `TestFailure("Stream finished…")` when the stream ends without
///   ever producing a value, so the two failure shapes are identifiable.
func awaitFirst<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
    let timeout = testWaitBackstop
    let stopwatch = BackstopStopwatch()
    let task = Task<T?, Never> {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    let timeoutTask = Task<Void, Never> {
        try? await MonotonicEngineClock().sleep(for: timeout)
        task.cancel()
    }
    defer { timeoutTask.cancel() }
    guard let value = await task.value else {
        if stopwatch.elapsed >= timeout {
            throw TestFailure.backstop(
                "Timed out waiting for stream value after \(timeout) s",
                stopwatch: stopwatch, timeout: timeout)
        }
        throw TestFailure("Stream finished without producing a value")
    }
    return value
}

// MARK: - Clock-parameterized client factory

/// Builds a `VsockGuestClient` on the clock `kind` names, for suites
/// parameterized over both production clocks (`EngineClockKind.allCases`).
func makeTestClient(
    kind: EngineClockKind,
    port: UInt32,
    label: String,
    retryInterval: TimeInterval,
    socketProvider: VsockSocketProvider? = nil
) -> VsockGuestClient {
    VsockGuestClient(
        port: port, label: label, clock: kind.makeClock(),
        retryInterval: retryInterval, socketProvider: socketProvider)
}

// MARK: - AtomicInt

/// Lock-protected integer for use in non-async closures (e.g. socket providers).
///
/// Exposes a `changed` gate so tests can `await changed.wait { value >= n }`
/// instead of polling — each `increment()` fires the gate.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int = 0

    /// Fires on every `increment()`; await it instead of polling `value`.
    let changed = AsyncGate()

    @discardableResult
    func increment() -> Int {
        let newValue = lock.withLock { () -> Int in
            storedValue += 1
            return storedValue
        }
        changed.notify()
        return newValue
    }

    var value: Int {
        lock.withLock { storedValue }
    }
}

// MARK: - AtomicBox

/// Lock-protected optional slot for handing a value between a non-async closure
/// and the test that installed it.
///
/// Two uses: back-filling a reference a closure needs but that only exists after
/// the closure is built (an agent whose own callback reads it), and recording
/// what a callback saw. `changed` fires on every `set`, so the reader awaits
/// instead of polling.
final class AtomicBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    /// Fires on every `set(_:)`; await it instead of polling `value`.
    let changed = AsyncGate()

    var value: Value? {
        lock.withLock { storedValue }
    }

    func set(_ newValue: Value?) {
        lock.withLock { storedValue = newValue }
        changed.notify()
    }
}

// MARK: - Host-side transfer driver

/// Reads one whole outbound transfer off the data connection the agent dialled
/// to answer a host `ClipboardRequest`: the reply describing the payload, the
/// payload bytes, and the trailer that ended them.
///
/// A macOS guest only ever initiates connections, so the transfer arrives on one
/// the agent opened rather than as frames on the control channel — the test
/// takes it from `connections`, the collector standing in for the host's data
/// listener. The reads block, so they run off the caller's actor.
func collectOutboundTransfer(
    transferID: UInt64, from connections: DialledDataConnections
) async throws -> ReceivedTransfer {
    let fd = try await connections.next()
    guard let received = await offCooperativePool({ try? receiveTransfer(fd: fd) }) else {
        throw TestFailure(
            "The agent's data connection for transfer \(transferID) carried nothing readable")
    }
    guard received.reply.transferID == transferID else {
        throw TestFailure(
            "The agent streamed transfer \(received.reply.transferID), not \(transferID)")
    }
    return received
}

func makeLogFrame(message: String) -> Frame {
    var frame = Frame()
    frame.protocolVersion = 1
    frame.logRecord = Kernova_V1_LogRecord.with {
        $0.timestampMs = 0
        $0.level = .info
        $0.subsystem = "test"
        $0.category = "test"
        $0.message = message
    }
    return frame
}
