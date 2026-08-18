import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Writes the descriptor a hand-driven sending peer's payload follows.
func writeTransferReply(
    fd: Int32, transferID: UInt64, isArchive: Bool, isInline: Bool, totalBytes: UInt64
) throws {
    try ClipboardDataConnection.writeFrame(
        makeTransferReplyFrame(
            transferID: transferID, isArchive: isArchive, isInline: isInline,
            totalBytes: Int(clamping: totalBytes)),
        fd: fd)
}

/// Copies everything from `source` to `destination`, changing one payload byte
/// on the way.
///
/// The one corruption the transport itself cannot notice: framing, sizes and
/// the trailer all still line up, so only the end-to-end SHA-256 catches it
/// (docs/CLIPBOARD.md §7). Buffered whole rather than streamed, so neither end
/// can park on the other.
func relayFlippingOneByte(from source: Int32, to destination: Int32) {
    defer {
        ClipboardDataConnection.end(fd: source)
        ClipboardDataConnection.end(fd: destination)
    }
    var buffered = Data()
    var block = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let got = block.withUnsafeMutableBytes { raw in
            (try? ClipboardDataConnection.read(fd: source, into: raw)) ?? 0
        }
        guard got > 0 else { break }
        buffered.append(contentsOf: block[..<got])
    }
    // The last byte before the trailer, so the flip always lands in the payload
    // whatever the reply frame's length came out as.
    let flipped = buffered.count - ClipboardTransferTrailer.byteCount - 1
    guard flipped >= 0 else { return }
    buffered[flipped] ^= 0xFF
    try? ClipboardDataConnection.write(fd: destination, buffered)
}

/// Everything left on `fd` up to end of stream, which is empty when the peer
/// closed its end without writing.
///
/// The read is bounded by a socket timeout, so a descriptor a regression left
/// open fails the test rather than parking it forever.
func drainUntilPeerCloses(_ fd: Int32, timeout: TimeInterval = 5) throws -> Data {
    ClipboardDataConnection.applySocketOptions(fd: fd, timeout: timeout)
    return try readToEnd(fd: fd)
}

/// `count` incompressible bytes, so a fixture's wire size tracks its payload.
func randomBytes(count: Int) throws -> Data {
    let urandom = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
    defer { try? urandom.close() }
    var bytes = Data()
    while bytes.count < count {
        guard let block = try urandom.read(upToCount: count - bytes.count), !block.isEmpty else {
            break
        }
        bytes.append(block)
    }
    return bytes
}

// MARK: - Collector

/// Gathers what both halves of a transfer report.
final class TransferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [UInt64: ClipboardContent.Representation] = [:]
    private var aborts: [ClipboardStreamAbortInfo] = []
    private var sendOutcomes: [UInt64: Bool] = [:]
    private var inboundTimings: [ClipboardTransferMetrics] = []
    private var outboundTimings: [ClipboardTransferMetrics] = []
    private var received: [(bytes: Int, total: Int)] = []
    private var sent: [(bytes: Int, total: Int)] = []

    /// Fires on every recorded event; await it instead of polling.
    let gate = AsyncGate()

    func complete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        lock.withLock { completed[id] = representation }
        gate.notify()
    }

    func abort(_ info: ClipboardStreamAbortInfo) {
        lock.withLock { aborts.append(info) }
        gate.notify()
    }

    func sendFinished(_ id: UInt64, success: Bool) {
        lock.withLock { sendOutcomes[id] = success }
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

    func receiveProgress(_ bytes: Int, _ total: Int) {
        lock.withLock { received.append((bytes, total)) }
        gate.notify()
    }

    func sendProgress(_ bytes: Int, _ total: Int) {
        lock.withLock { sent.append((bytes, total)) }
        gate.notify()
    }

    /// The representation one transfer delivered, if it completed.
    func representation(_ id: UInt64) -> ClipboardContent.Representation? {
        lock.withLock { completed[id] }
    }
    /// Every abort delivered, in order.
    var abortInfos: [ClipboardStreamAbortInfo] { lock.withLock { aborts } }
    /// How many aborts were delivered.
    var abortCount: Int { lock.withLock { aborts.count } }
    /// Whether one transfer's send reported success, or `nil` if it has not
    /// finished.
    func sendOutcome(_ id: UInt64) -> Bool? { lock.withLock { sendOutcomes[id] } }
    /// How many sends have finished.
    var sendCount: Int { lock.withLock { sendOutcomes.count } }
    /// Metrics the *receiver* reported, kept apart from the sender's so a test
    /// asserting one direction reported nothing cannot be satisfied by the
    /// other.
    var inboundMetrics: [ClipboardTransferMetrics] { lock.withLock { inboundTimings } }
    /// Metrics the *sender* reported.
    var outboundMetrics: [ClipboardTransferMetrics] { lock.withLock { outboundTimings } }
    /// Every `(bytesReceived, totalBytes)` the receiving side reported.
    var receiveProgressReports: [(bytes: Int, total: Int)] { lock.withLock { received } }
    /// Every `(bytesSent, totalBytes)` the sending side reported.
    var sendProgressReports: [(bytes: Int, total: Int)] { lock.withLock { sent } }
}

// MARK: - Staging

/// Answers a receiver's free-space query and remembers the staging root it was
/// asked about.
///
/// A receiver reserves its own extract destination, so the root its free-space
/// guard is queried against is the only handle a test has on what a transfer put
/// on disk — and every archived transfer queries it before it reserves anything.
final class StagingProbe: @unchecked Sendable {
    private let answer: @Sendable (Int) -> Int64
    private let state = Box<(queries: Int, root: URL?)>((0, nil))

    /// - Parameter freeSpace: answers the *n*th query, counted from zero, so a
    ///   test can be roomy at the pre-flight and full from the next check on.
    init(freeSpace: @escaping @Sendable (Int) -> Int64 = { _ in 100 << 30 }) {
        answer = freeSpace
    }

    /// The provider to hand a ``TransferHarness``.
    var provider: ClipboardFileStaging.FreeSpaceProvider {
        { [self] url in
            let seen = state.value.queries
            state.value = (seen + 1, url)
            return answer(seen)
        }
    }

    /// How many times a transfer asked whether it had room.
    var queryCount: Int { state.value.queries }

    /// Every file staged under the root a transfer asked about.
    func stagedFiles() throws -> [URL] {
        materializedFiles(under: try #require(state.value.root))
    }
}

// MARK: - Harness

/// Wires a real ``ClipboardTransferInbox`` and ``ClipboardTransferOutbox`` over
/// socketpairs, in whichever header order the direction implies.
///
/// ``pull(transferID:generation:plan:representation:...)`` is the guest-receives
/// order — the receiver dials and writes the request, the sender answers on the
/// accepted end. ``push(transferID:generation:plan:representation:...)`` is the
/// host-receives order — the sender dials and writes the reply, the receiver
/// adopts the accepted end. Both run the shipping code on both ends.
final class TransferHarness: @unchecked Sendable {
    private let staging: ClipboardFileStaging
    private let stagingTempRoot: URL
    let inbox: ClipboardTransferInbox
    let outbox: ClipboardTransferOutbox
    let collector = TransferCollector()

    /// An extra hook on each receive-progress report.
    ///
    /// Fires on the receiving transfer's own queue, so a test that must act at
    /// a point *inside* the stream — cancelling once bytes are moving — does it
    /// there rather than from its own thread, where a loaded runner decides how
    /// far the transfer got first.
    let onReceiveProgress = Box<(@Sendable (Int, Int) -> Void)?>(nil)

    /// An extra hook on each send-progress report, for a test that must act at a
    /// point inside the *stream* rather than inside the extract behind it.
    ///
    /// Fires on the sending transfer's own queue, after each block that got
    /// away — so a test pinning an event to "the transfer is under way" pins it
    /// to the transfer rather than to how fast the two ends happen to run.
    let onSendProgress = Box<(@Sendable (Int, Int) -> Void)?>(nil)

    init(
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        socketTimeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        extractPacingBytes: Int = ClipboardStreamTuning.extractPacingBytes
    ) {
        stagingTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        staging = ClipboardFileStaging(
            label: "transfer-\(UUID().uuidString)", tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        let collector = self.collector
        inbox = ClipboardTransferInbox(
            staging: staging, socketTimeout: socketTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            minimumExtractAllowance: minimumExtractAllowance,
            extractPacingBytes: extractPacingBytes,
            onTransferTimed: { collector.timedInbound($0) })
        outbox = ClipboardTransferOutbox(
            socketTimeout: socketTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            onTransferTimed: { collector.timedOutbound($0) })
    }

    func tearDown() {
        inbox.cancelAll()
        outbox.cancelAll()
        staging.sweep()
        try? FileManager.default.removeItem(at: stagingTempRoot)
    }

    /// A receiver on this harness's staging, for a test driving one transfer's
    /// own lifecycle rather than a round trip through the inbox.
    func makeReceiver(
        transferID: UInt64, generation: UInt64, plan: ClipboardTransferReceiver.Plan,
        source: ClipboardTransferReceiver.Source
    ) -> ClipboardTransferReceiver {
        ClipboardTransferReceiver(
            transferID: transferID, generation: generation, source: source,
            plan: plan, staging: staging)
    }

    /// Registers the pull for `transferID` with the inbox.
    func expect(transferID: UInt64, plan: ClipboardTransferReceiver.Plan) {
        let collector = self.collector
        inbox.awaitTransfer(
            transferID, plan: plan,
            onComplete: { collector.complete(transferID, $0) },
            onAbort: { collector.abort($0) },
            onProgress: { [onReceiveProgress] bytes, total in
                collector.receiveProgress(bytes, total)
                onReceiveProgress.value?(bytes, total)
            })
    }

    /// Guest-receives order: the inbox dials and writes the request, and the
    /// far end is handed to `serve`.
    func openPull(
        transferID: UInt64, generation: UInt64,
        maxAcceptByteCount: UInt64 = ClipboardStreamTuning.unlimitedAcceptByteCount,
        serve: @escaping @Sendable (Int32, Kernova_V1_ClipboardTransferRequest) -> Void
    ) {
        inbox.open(
            transferID: transferID, generation: generation,
            maxAcceptByteCount: maxAcceptByteCount
        ) {
            try dialToPeer { far in
                guard let request = readTransferRequest(fd: far) else {
                    ClipboardDataConnection.end(fd: far)
                    return
                }
                serve(far, request)
            }
        }
    }

    /// A full guest-receives round trip: the inbox dials, the outbox answers.
    func pull(
        transferID: UInt64, generation: UInt64, plan: ClipboardTransferReceiver.Plan,
        representation: ClipboardContent.Representation, isInline: Bool = false,
        maxAcceptByteCount: UInt64 = ClipboardStreamTuning.unlimitedAcceptByteCount,
        isCurrent: @escaping @Sendable (UInt64) -> Bool = { _ in true }
    ) {
        expect(transferID: transferID, plan: plan)
        let outbox = self.outbox
        let collector = self.collector
        let onSendProgress = self.onSendProgress
        openPull(
            transferID: transferID, generation: generation, maxAcceptByteCount: maxAcceptByteCount
        ) { far, request in
            outbox.serve(
                transferID: request.transferID, generation: request.generation,
                representation: representation, maxAcceptByteCount: request.maxAcceptByteCount,
                isInline: isInline, isCurrent: isCurrent, link: .accepted(far),
                onProgress: { bytes, total in
                    collector.sendProgress(bytes, total)
                    onSendProgress.value?(bytes, total)
                },
                onComplete: { collector.sendFinished(request.transferID, success: $0) })
        }
    }

    /// A full host-receives round trip: the outbox dials and writes the reply,
    /// the inbox adopts the accepted end.
    func push(
        transferID: UInt64, generation: UInt64, plan: ClipboardTransferReceiver.Plan,
        representation: ClipboardContent.Representation, isInline: Bool = false,
        maxAcceptByteCount: UInt64 = ClipboardStreamTuning.unlimitedAcceptByteCount,
        isCurrent: @escaping @Sendable (UInt64) -> Bool = { _ in true }
    ) {
        expect(transferID: transferID, plan: plan)
        let inbox = self.inbox
        let collector = self.collector
        let onSendProgress = self.onSendProgress
        outbox.serve(
            transferID: transferID, generation: generation, representation: representation,
            maxAcceptByteCount: maxAcceptByteCount, isInline: isInline, isCurrent: isCurrent,
            link: .dial {
                try dialToPeer { far in
                    guard let reply = readTransferReply(fd: far) else {
                        ClipboardDataConnection.end(fd: far)
                        return
                    }
                    inbox.adopt(fd: far, reply: reply)
                }
            },
            onProgress: { bytes, total in
                collector.sendProgress(bytes, total)
                onSendProgress.value?(bytes, total)
            },
            onComplete: { collector.sendFinished(transferID, success: $0) })
    }
}
