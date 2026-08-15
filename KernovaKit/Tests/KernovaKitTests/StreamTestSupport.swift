import Darwin
import Foundation
import KernovaTestSupport

@testable import KernovaKit

/// A test failure with a message, thrown by the streaming-engine test helpers.
struct StreamTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Socket pair

/// Two `VsockChannel`s connected by a started `socketpair(AF_UNIX, SOCK_STREAM)`.
func makeStartedChannelPair() throws -> (a: VsockChannel, b: VsockChannel) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let a = VsockChannel(fileDescriptor: fds[0])
    let b = VsockChannel(fileDescriptor: fds[1])
    a.start()
    b.start()
    return (a, b)
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
/// `capacityBytes`/`pacingBytes` mirror what the receiver passes its own
/// factory — the harness window — so a wrapped sink paces its guard exactly as
/// an unwrapped one does.
func makeExtractSink(
    destinationURL: URL, label: String, windowBytes: Int,
    onOutputAdvanced: @escaping @Sendable (Int) throws -> Void
) -> ClipboardArchiveExtractSink {
    ClipboardArchiveExtractSink(
        destinationURL: destinationURL, label: label,
        capacityBytes: windowBytes, pacingBytes: windowBytes,
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

    var writeErrorCode: String { wrapped.writeErrorCode }
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

    var writeErrorCode: String { wrapped.writeErrorCode }
}

/// A `StagingSink` that throws on its `failingWrite`-th write (1-based),
/// wrapping a real staging sink otherwise — models a volume that fails an
/// append mid-stream.
final class FailingSink: StagingSink, @unchecked Sendable {
    private let wrapped: any StagingSink
    private let failingWrite: Int
    private let lock = NSLock()
    private var attempts = 0

    init(wrapping sink: any StagingSink, failingWrite: Int) {
        wrapped = sink
        self.failingWrite = failingWrite
    }

    func write(_ data: Data) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        guard attempt != failingWrite else {
            throw StreamTestFailure("Injected staging write failure on write \(attempt)")
        }
        try wrapped.write(data)
    }

    @discardableResult
    func commit() throws -> URL { try wrapped.commit() }

    func abort() { wrapped.abort() }

    func cancel() { wrapped.cancel() }

    var writeErrorCode: String { wrapped.writeErrorCode }
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
    private var timings: [ClipboardTransferMetrics] = []
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
    func timed(_ metrics: ClipboardTransferMetrics) {
        lock.withLock { timings.append(metrics) }
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
    var timedMetrics: [ClipboardTransferMetrics] { lock.withLock { timings } }
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

    init(
        clock: any EngineClock = makePlatformEngineClock(),
        chunkSize: Int,
        windowBytes: Int,
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
        let builtSender: ClipboardStreamSender
        if let archiveSource {
            builtSender = ClipboardStreamSender(
                channel: a, chunkSize: chunkSize, windowBytes: windowBytes,
                noAckTimeout: noAckTimeout, maxResidentInlineBytes: maxResidentInlineBytes,
                archiveSource: archiveSource)
        } else {
            builtSender = ClipboardStreamSender(
                channel: a, chunkSize: chunkSize, windowBytes: windowBytes,
                noAckTimeout: noAckTimeout, maxResidentInlineBytes: maxResidentInlineBytes)
        }
        sender = builtSender
        let collector = self.collector
        receiver = ClipboardStreamReceiver(
            clock: clock,
            channel: b, staging: staging, windowBytes: windowBytes,
            ackLatencyBound: ackLatencyBound, stallTimeout: stallTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            minimumExtractAllowance: minimumExtractAllowance,
            sinkFactory: sinkFactory,
            onTransferTimed: { metrics in collector.timed(metrics) },
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
                            if suppressAcks { break }  // model a peer that never acks
                            sender.handleAck(
                                transferID: x.transferID, bytesConsumed: x.bytesConsumed,
                                windowBytes: x.windowBytes)
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
