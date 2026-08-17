import Foundation
import KernovaTestSupport

@testable import KernovaKit

/// A test failure with a message, thrown by the streaming-engine test helpers.
struct StreamTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Payloads

/// `count` bytes following `(i * multiplier + offset) mod 256` — a fixed,
/// incompressible-enough pattern built with a plain loop, so no test carries a
/// closure the type checker has to unpick.
func patternedBytes(count: Int, multiplier: Int, offset: Int) -> Data {
    var bytes = Data(count: count)
    for index in 0..<count {
        bytes[index] = UInt8(truncatingIfNeeded: index &* multiplier &+ offset)
    }
    return bytes
}

// MARK: - Staging sink doubles

/// The extract sink a test double stands in front of: the production pipeline,
/// wired to the guard the receiver handed its factory, so the ceiling and
/// free-space checks still fire through the double.
///
/// `capacityBytes`/`pacingBytes` are passed through unchanged from what the
/// receiver would hand its own factory, so a wrapped sink paces its guard
/// exactly as an unwrapped one does.
func makeExtractSink(
    destinationURL: URL, label: String, capacityBytes: Int, pacingBytes: Int,
    onOutputAdvanced: @escaping @Sendable (Int) throws -> Void
) -> ClipboardArchiveExtractSink {
    ClipboardArchiveExtractSink(
        destinationURL: destinationURL, label: label,
        capacityBytes: capacityBytes, pacingBytes: pacingBytes,
        onOutputAdvanced: onOutputAdvanced)
}

/// A `StagingSink` that parks every `write` until the test allows it through,
/// wrapping a real staging sink so everything else (bytes on disk, commit,
/// abort) behaves exactly as in production.
///
/// The receiver's write lane holds a backlog only while an append is
/// outstanding, which a real staging sink never does long enough to observe —
/// this makes that window as wide as a test needs, so the pipelining (#615) can
/// be asserted deterministically instead of by timing.
final class GatedSink: StagingSink, @unchecked Sendable {
    private let wrapped: any StagingSink
    private let condition = NSCondition()
    private var allowance = 0
    private var started = 0
    private var completed = 0
    /// Notified when a write parks and after each completed write, so tests
    /// wait event-driven.
    let gate = AsyncGate()

    init(wrapping sink: any StagingSink) { wrapped = sink }

    /// Writes the receiver's write lane has entered — the last of them is
    /// parked in the gate whenever `startedWrites > completedWrites`, which
    /// pins the lane at a known point.
    var startedWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    /// Writes that have fully completed (bytes on disk, `writtenBytes`
    /// about to advance).
    var completedWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return completed
    }

    /// Lets `count` more parked (or future) writes through.
    func allow(_ count: Int) {
        condition.lock()
        allowance += count
        condition.broadcast()
        condition.unlock()
    }

    /// Lets every remaining write through.
    func allowAll() {
        condition.lock()
        allowance = .max
        condition.broadcast()
        condition.unlock()
    }

    func write(_ data: Data) throws {
        condition.lock()
        started += 1
        condition.unlock()
        gate.notify()
        condition.lock()
        while allowance == 0 { condition.wait() }
        if allowance != .max { allowance -= 1 }
        condition.unlock()
        try wrapped.write(data)
        condition.lock()
        completed += 1
        condition.unlock()
        gate.notify()
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }

    func cancel() { wrapped.cancel() }

    var writeErrorCode: ClipboardStreamAbortCode { wrapped.writeErrorCode }
}

/// A `StagingSink` that silently discards its `droppingWrite`-th write
/// (1-based) — accepting the bytes without storing them, and without throwing.
///
/// Models the one corruption the end-to-end digest cannot catch: the digest is
/// taken over the bytes that *arrive*, so bytes lost between the receive lane
/// and the sink leave both the size and SHA-256 checks satisfied.
final class SilentlyDroppingSink: StagingSink, @unchecked Sendable {
    private let wrapped: any StagingSink
    private let droppingWrite: Int
    private let lock = NSLock()
    private var attempts = 0

    init(wrapping sink: any StagingSink, droppingWrite: Int) {
        wrapped = sink
        self.droppingWrite = droppingWrite
    }

    func write(_ data: Data) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt != droppingWrite else { return }
        try wrapped.write(data)
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }

    func cancel() { wrapped.cancel() }

    var writeErrorCode: ClipboardStreamAbortCode { wrapped.writeErrorCode }
}

/// A `StagingSink` that throws on its `failingWrite`-th write (1-based),
/// wrapping a real staging sink otherwise — models a volume that fails an
/// append mid-stream.
///
/// `throwing` names the failure, so a test can inject one the receiver reads as
/// something other than a plain write error — a
/// ``ClipboardArchiveStreamError`` the extract raises on its own terms.
final class FailingSink: StagingSink, @unchecked Sendable {
    private let wrapped: any StagingSink
    private let failingWrite: Int
    private let injected: (any Error)?
    private let lock = NSLock()
    private var attempts = 0

    init(wrapping sink: any StagingSink, failingWrite: Int, throwing error: (any Error)? = nil) {
        wrapped = sink
        self.failingWrite = failingWrite
        injected = error
    }

    func write(_ data: Data) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt != failingWrite else {
            throw injected
                ?? StreamTestFailure("Injected staging write failure on write \(attempt)")
        }
        try wrapped.write(data)
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }

    func cancel() { wrapped.cancel() }

    var writeErrorCode: ClipboardStreamAbortCode { wrapped.writeErrorCode }
}

/// A `ChunkReader` that parks every read until it is closed.
///
/// A real archive source parks whenever its encoder has produced nothing yet —
/// a slow walk over a network or removable volume — and that park is only
/// escapable because an abort reaches the source. Standing this in makes the
/// window as wide as a test needs instead of racing a real encoder.
final class ParkingChunkReader: CancellableChunkReader, @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var reads = 0
    /// Notified once a read has parked, so a test can abort at a known point.
    let parked = AsyncGate()

    /// Reads that have entered and not yet returned.
    var parkedReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return reads
    }

    func read(upTo count: Int) -> Data? {
        condition.lock()
        reads += 1
        condition.unlock()
        parked.notify()
        condition.lock()
        while !closed { condition.wait() }
        condition.unlock()
        return nil
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A `ChunkReader` that vends prepared bytes, charging a fixed interval on an
/// injected clock to each read.
///
/// Stands in for a source running behind the transport — an encoder that has
/// produced nothing yet. The wait is real to the sender's accounting and
/// instant in wall time, so a test asserts an exact figure instead of a
/// measured one.
final class ClockAdvancingChunkReader: CancellableChunkReader, @unchecked Sendable {
    private let clock: TestEngineClock
    private let secondsPerRead: TimeInterval
    private let lock = NSLock()
    private var remaining: Data
    private var reads = 0

    init(bytes: Data, clock: TestEngineClock, secondsPerRead: TimeInterval) {
        self.remaining = bytes
        self.clock = clock
        self.secondsPerRead = secondsPerRead
    }

    /// Reads entered, including the empty one that ends the source.
    var readCount: Int { lock.withLock { reads } }

    func read(upTo count: Int) -> Data? {
        clock.advance(seconds: secondsPerRead)
        return lock.withLock {
            reads += 1
            let taken = remaining.prefix(count)
            remaining = remaining.dropFirst(taken.count)
            return Data(taken)
        }
    }

    func close() {}
}

/// Holds the receiver's acks back from the sender, and can later let them go.
///
/// A test that measures a credit stall has to park the sender *and then* let it
/// finish, which the plain never-ack model cannot do. Only the latest held ack
/// per transfer is replayed: `handleAck` carries a cumulative figure and heals
/// itself with `max`, so the earlier ones say nothing the last one does not.
final class AckGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var held: [UInt64: Kernova_V1_ClipboardStreamAck] = [:]

    init(isOpen: Bool) { self.isOpen = isOpen }

    /// Returns the ack to forward, or `nil` when the gate holds it back.
    func admit(_ ack: Kernova_V1_ClipboardStreamAck) -> Kernova_V1_ClipboardStreamAck? {
        lock.withLock {
            guard !isOpen else { return ack }
            held[ack.transferID] = ack
            return nil
        }
    }

    /// Opens the gate, handing back the acks to replay.
    func open() -> [Kernova_V1_ClipboardStreamAck] {
        lock.withLock {
            isOpen = true
            let pending = Array(held.values)
            held.removeAll()
            return pending
        }
    }
}

/// A `@Sendable` closure slot that can be filled after the object firing it has
/// been built — which a hook reaching back into its own harness has to be.
final class SendableHook<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (Value) -> Void)?

    var value: (@Sendable (Value) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func fire(_ value: Value) { self.value?(value) }
}

// MARK: - Collector

/// Gathers the completed representations and aborts a receiver delivers, plus
/// the `Begin`/`End` frames that announced and closed each transfer.
///
/// An archived transfer's wire size and digest are only knowable from those two
/// frames — the archive is never materialized, and its bytes are not the
/// payload's — so a test reads them here rather than re-encoding the source and
/// hoping the encoder is byte-deterministic.
final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [UInt64: ClipboardContent.Representation] = [:]
    private var aborts: [ClipboardStreamAbortInfo] = []
    private var inboundTimings: [ClipboardTransferMetrics] = []
    private var outboundTimings: [ClipboardTransferMetrics] = []
    private var acks: [Kernova_V1_ClipboardStreamAck] = []
    private var begins: [UInt64: Kernova_V1_ClipboardStreamBegin] = [:]
    private var ends: [UInt64: Kernova_V1_ClipboardStreamEnd] = [:]
    let gate = AsyncGate()

    func began(_ begin: Kernova_V1_ClipboardStreamBegin) {
        lock.withLock { begins[begin.transferID] = begin }
        gate.notify()
    }
    func ended(_ end: Kernova_V1_ClipboardStreamEnd) {
        lock.withLock { ends[end.transferID] = end }
        gate.notify()
    }

    func complete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        lock.withLock { completed[id] = representation }
        gate.notify()
    }
    func abort(_ info: ClipboardStreamAbortInfo) {
        lock.withLock { aborts.append(info) }
        gate.notify()
    }
    func timedInbound(_ metrics: ClipboardTransferMetrics) {
        lock.withLock { inboundTimings.append(metrics) }
        gate.notify()
    }
    func timedOutbound(_ metrics: ClipboardTransferMetrics) {
        lock.withLock { outboundTimings.append(metrics) }
        gate.notify()
    }
    func ack(_ ack: Kernova_V1_ClipboardStreamAck) {
        lock.withLock { acks.append(ack) }
        gate.notify()
    }

    var completedCount: Int { lock.withLock { completed.count } }
    func representation(_ id: UInt64) -> ClipboardContent.Representation? {
        lock.withLock { completed[id] }
    }
    var abortInfos: [ClipboardStreamAbortInfo] { lock.withLock { aborts } }
    var abortCount: Int { lock.withLock { aborts.count } }
    /// Metrics the *receiver* reported, kept apart from the sender's so a test
    /// asserting one direction reported nothing cannot be satisfied by the
    /// other.
    var inboundMetrics: [ClipboardTransferMetrics] { lock.withLock { inboundTimings } }
    /// Metrics the *sender* reported.
    var outboundMetrics: [ClipboardTransferMetrics] { lock.withLock { outboundTimings } }
    /// The `ClipboardStreamBegin` that announced one transfer.
    func begin(_ id: UInt64) -> Kernova_V1_ClipboardStreamBegin? {
        lock.withLock { begins[id] }
    }
    /// The `ClipboardStreamEnd` that closed one transfer — its `total_bytes` is
    /// the wire size and its `sha256` the digest of the wire bytes.
    func end(_ id: UInt64) -> Kernova_V1_ClipboardStreamEnd? {
        lock.withLock { ends[id] }
    }
    /// The `bytes_consumed` sequence of every recorded ack for one transfer.
    func ackedByteCounts(_ id: UInt64) -> [UInt64] {
        lock.withLock { acks.filter { $0.transferID == id }.map(\.bytesConsumed) }
    }
}

// MARK: - Harness

/// Wires a `ClipboardStreamSender` (channel A) and `ClipboardStreamReceiver`
/// (channel B) over a socketpair, with two routing tasks standing in for the
/// owning services: A's inbound acks/aborts feed the sender; B's inbound
/// begin/chunk/end/abort feed the receiver.
final class StreamHarness: @unchecked Sendable {
    let sender: ClipboardStreamSender
    let receiver: ClipboardStreamReceiver
    let staging: ClipboardFileStaging
    /// Parent of the staging root; tests scan it for materialized temp files.
    let stagingTempRoot: URL
    let collector = StreamCollector()

    private let a: VsockChannel
    private let b: VsockChannel
    private var routeTasks: [Task<Void, Never>] = []
    private let ackGate: AckGate
    private let creditWaitHook: SendableHook<UInt64>

    /// Runs on the transfer's own queue each time the sender is about to wait
    /// for credit, with its stall reading already taken.
    ///
    /// Installed after construction, since a hook that releases this harness's
    /// acks needs the harness the sender is being built into.
    var onCreditWait: (@Sendable (_ transferID: UInt64) -> Void)? {
        get { creditWaitHook.value }
        set { creditWaitHook.value = newValue }
    }

    /// Lets through the acks `suppressAcks` held back, replaying the latest one
    /// per transfer so a sender parked on credit resumes.
    func releaseAcks() {
        for ack in ackGate.open() {
            sender.handleAck(
                transferID: ack.transferID, bytesConsumed: ack.bytesConsumed,
                windowBytes: ack.windowBytes)
        }
    }

    // `senderClock` defaults to the receiver's `clock`. A test that freezes the
    // sender's clock to assert an exact stage figure gives it its own, since a
    // frozen receiver clock would also disable that side's ack-latency fallback
    // and stall watchdog.
    init(
        clock: any EngineClock = makePlatformEngineClock(),
        senderClock: (any EngineClock)? = nil,
        chunkSize: Int,
        windowBytes: Int,
        // Each defaults to the injected window, so a test pinning a tiny window
        // to pace its guard or park its encoder gets that from `windowBytes`
        // alone.
        encodePipeBytes: Int? = nil,
        extractPipeBytes: Int? = nil,
        extractPacingBytes: Int? = nil,
        noAckTimeout: TimeInterval = 10,
        ackLatencyBound: TimeInterval = ClipboardStreamTuning.ackLatencyBound,
        stallTimeout: TimeInterval = ClipboardStreamTuning.inboundStallTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        suppressAcks: Bool = false,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        sinkFactory: ClipboardSinkFactory? = nil,
        archiveSource: ClipboardArchiveSourceFactory? = nil
    ) throws {
        (a, b) = try makeStartedChannelPair()
        stagingTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        staging = ClipboardFileStaging(
            label: "harness-\(UUID().uuidString)",
            tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        let collector = self.collector
        let ackGate = AckGate(isOpen: !suppressAcks)
        self.ackGate = ackGate
        let creditWaitHook = SendableHook<UInt64>()
        self.creditWaitHook = creditWaitHook
        sender = ClipboardStreamSender(
            clock: senderClock ?? clock,
            channel: a, chunkSize: chunkSize, windowBytes: windowBytes,
            encodePipeBytes: encodePipeBytes ?? windowBytes,
            noAckTimeout: noAckTimeout, maxResidentInlineBytes: maxResidentInlineBytes,
            onTransferTimed: { metrics in collector.timedOutbound(metrics) },
            onCreditWait: { id in creditWaitHook.fire(id) },
            archiveSource: archiveSource ?? ClipboardStreamSender.defaultArchiveSource)
        receiver = ClipboardStreamReceiver(
            clock: clock,
            channel: b, staging: staging, windowBytes: windowBytes,
            extractPipeBytes: extractPipeBytes ?? windowBytes,
            extractPacingBytes: extractPacingBytes ?? windowBytes,
            ackLatencyBound: ackLatencyBound, stallTimeout: stallTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            minimumExtractAllowance: minimumExtractAllowance,
            sinkFactory: sinkFactory,
            onTransferTimed: { metrics in collector.timedInbound(metrics) },
            onComplete: { id, rep in collector.complete(id, rep) },
            onAbort: { info in collector.abort(info) })

        let sender = self.sender
        let receiver = self.receiver
        let a = self.a
        let b = self.b
        routeTasks.append(
            Task {
                do {
                    for try await frame in b.incoming {
                        switch frame.payload {
                        case .clipboardStreamBegin(let x):
                            collector.began(x)
                            receiver.handleBegin(x)
                        case .clipboardChunk(let x): receiver.handleChunk(x)
                        case .clipboardStreamEnd(let x):
                            collector.ended(x)
                            receiver.handleEnd(x)
                        case .clipboardStreamAbort(let x): receiver.handleAbort(x)
                        default: break
                        }
                    }
                } catch {}
            })
        routeTasks.append(
            Task {
                do {
                    for try await frame in a.incoming {
                        switch frame.payload {
                        case .clipboardStreamAck(let x):
                            collector.ack(x)
                            // Models a peer that never acks — until a test
                            // opens the gate.
                            guard let admitted = ackGate.admit(x) else { break }
                            sender.handleAck(
                                transferID: admitted.transferID,
                                bytesConsumed: admitted.bytesConsumed,
                                windowBytes: admitted.windowBytes)
                        case .clipboardStreamAbort(let x):
                            sender.handleAbort(transferID: x.transferID)
                        default: break
                        }
                    }
                } catch {}
            })
    }

    func tearDown() {
        routeTasks.forEach { $0.cancel() }
        a.close()
        b.close()
        staging.sweep()
    }
}
