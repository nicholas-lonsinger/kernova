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

// MARK: - Host-side stream driver

/// Collects the `Begin`/`Chunk`(s)/`End` of one outbound transfer the agent
/// sends in reply to a `ClipboardRequest`, returning the reassembled bytes and
/// the transfer's metadata.
///
/// The agent's `ClipboardStreamSender` waits for a first ack (the go-signal)
/// before chunking, so the caller must send `makeAckFrame(...)` *after* the
/// `ClipboardRequest` to release it. This driver reads frames until `End`,
/// re-acking each chunk so a small test window can't stall the transfer.
struct CollectedTransfer {
    var begin: Kernova_V1_ClipboardStreamBegin
    var bytes: Data
    var end: Kernova_V1_ClipboardStreamEnd
}

/// Reads `Begin`→`Chunk`(s)→`End` for `transferID` off `channel`, acking as it
/// goes.
///
/// Sends the go-signal ack itself, on receipt of `Begin` — mirroring the real
/// receiver, which acks in response to `Begin`. (The caller must not pre-send an
/// ack: the agent's consume loop processes stream frames off-main, so an ack
/// sent before the `ClipboardRequest` is handled could overtake it and be
/// dropped before the transfer is registered.)
func collectOutboundTransfer(
    transferID: UInt64, from channel: VsockChannel
) async throws -> CollectedTransfer {
    var begin: Kernova_V1_ClipboardStreamBegin?
    var assembled = Data()

    while true {
        let frame = try await nextFrame(from: channel)
        switch frame.payload {
        case .clipboardStreamBegin(let b) where b.transferID == transferID:
            begin = b
            // Go-signal: release the sender now that Begin has arrived.
            try channel.send(makeAckFrame(transferID: transferID, bytesConsumed: 0))
        case .clipboardChunk(let c) where c.transferID == transferID:
            assembled.append(c.data)
            // Re-ack cumulative progress so a small window keeps advancing.
            try channel.send(
                makeAckFrame(transferID: transferID, bytesConsumed: assembled.count))
        case .clipboardStreamEnd(let e) where e.transferID == transferID:
            guard let begin else {
                throw TestFailure("Got End for transfer \(transferID) before Begin")
            }
            return CollectedTransfer(begin: begin, bytes: assembled, end: e)
        case .clipboardStreamAbort(let a) where a.transferID == transferID:
            throw TestFailure(
                "Outbound transfer \(transferID) aborted: \(a.code) — \(a.message)")
        default:
            // A frame for another transfer/payload — keep reading.
            continue
        }
    }
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
