import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The sender's own stage timings, over the real sender and receiver on a
/// socketpair.
@Suite("ClipboardOutboundMetrics")
struct ClipboardOutboundMetricsTests {
    private static let chunk = 4096
    private static let window = 16384  // 4 chunks

    private func harness(
        senderClock: (any EngineClock)? = nil,
        noAckTimeout: TimeInterval = 10,
        suppressAcks: Bool = false,
        archiveSource: ClipboardArchiveSourceFactory? = nil
    ) throws -> StreamHarness {
        try StreamHarness(
            senderClock: senderClock,
            chunkSize: Self.chunk, windowBytes: Self.window, noAckTimeout: noAckTimeout,
            suppressAcks: suppressAcks,
            freeSpaceProvider: { _ in 100 << 30 },
            archiveSource: archiveSource)
    }

    private func tempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    /// Bytes no compressor can shrink, so an archive's wire count stays clear of
    /// the payload's — from a fixed sequence, so a failure reproduces.
    private func incompressibleBytes(count: Int) -> Data {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var bytes = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        return bytes
    }

    /// The priming a requester performs before its `ClipboardRequest` goes out:
    /// an archived transfer is refused at Begin unless a pull awaits it.
    private func prime(
        _ harness: StreamHarness, id: UInt64, advertised: Int,
        extractsDirectoryNamed: String? = nil
    ) {
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, extractsDirectoryNamed: extractsDirectoryNamed, advertisedByteCount: advertised,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) })
    }

    /// The sender's own verdict for one transfer.
    ///
    /// It is the terminal signal a metrics test wants: `onComplete` fires from a
    /// `defer`, so by the time it lands the decision to report — or not to — has
    /// already been made, and an "it reported nothing" assertion cannot run early.
    private final class SendOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        let gate = AsyncGate()

        func record(_ success: Bool) {
            lock.withLock { stored = success }
            gate.notify()
        }

        var succeeded: Bool? { lock.withLock { stored } }
    }

    /// Lets a per-chunk hook act exactly once.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        /// `true` to the first caller only.
        func claim() -> Bool {
            lock.withLock {
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }

    @Test("a raw inline send reports its own metrics, with the wire count left unstated")
    func rawInlineSendReportsMetrics() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        let payload = Data(repeating: 0x42, count: Self.chunk * 2 + 17)
        let outcome = SendOutcome()
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: payload),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true },
            onComplete: { outcome.record($0) })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        #expect(metrics.transferID == 1)
        #expect(metrics.uti == "public.utf8-plain-text")
        #expect(sent.isArchived == false)
        // Raw: the wire bytes *are* the payload, so the summary stays silent
        // about them.
        #expect(metrics.byteCount == payload.count)
        #expect(metrics.wireByteCount == payload.count)
        #expect(!metrics.logSummary.contains("wire bytes"))
        #expect(metrics.logSummary.contains("raw"))
        #expect(sent.chunkCount == 3)
        #expect(metrics.duration > .zero)
        let ramp = try #require(sent.timeToFirstChunk)
        #expect(ramp <= metrics.duration)
        #expect(metrics.inbound == nil)

        // The wire count the peer was told matches what the sender counted.
        try await harness.collector.gate.wait { harness.collector.end(1) != nil }
        let end = try #require(harness.collector.end(1))
        #expect(Int(end.totalBytes) == metrics.wireByteCount)
        #expect(outcome.succeeded == true)
    }

    @Test("an archived file send counts the archive on the wire and the payload it expands to")
    func archivedFileSendReportsMetrics() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        let bytes = incompressibleBytes(count: Self.chunk * 5 + 99)
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        try await harness.collector.gate.wait { harness.collector.end(1) != nil }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)
        let end = try #require(harness.collector.end(1))

        #expect(sent.isArchived)
        #expect(metrics.wireByteCount == Int(end.totalBytes))
        #expect(metrics.wireByteCount != metrics.byteCount)
        // The payload figure is the uncompressed archive — the file plus its
        // entry header — which is the unit the offer's estimate is in.
        #expect(metrics.byteCount >= bytes.count)
        #expect(metrics.logSummary.contains("archive"))
        #expect(metrics.logSummary.contains("\(metrics.wireByteCount) wire bytes"))
        #expect(sent.chunkCount > 0)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a folder send reports metrics in the tree's unit")
    func folderSendReportsMetrics() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "outbound-metrics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try "readme".write(
            to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "nested".write(
            to: source.appendingPathComponent("sub/n.txt"), atomically: true, encoding: .utf8)

        prime(harness, id: 1, advertised: 0, extractsDirectoryNamed: "Project")
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                directorySourceURL: source,
                estimatedByteCount: ClipboardArchive.estimatedByteCount(at: source),
                filename: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        try await harness.collector.gate.wait { harness.collector.end(1) != nil }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)
        let end = try #require(harness.collector.end(1))

        #expect(sent.isArchived)
        #expect(metrics.wireByteCount == Int(end.totalBytes))
        #expect(metrics.byteCount > 0)
        #expect(sent.chunkCount > 0)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a zero-byte send reports no chunks and no ramp")
    func zeroByteSendReportsNoChunks() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: Data()),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        #expect(sent.chunkCount == 0)
        #expect(sent.timeToFirstChunk == nil)
        #expect(metrics.byteCount == 0)
        #expect(metrics.wireByteCount == 0)
        #expect(!metrics.logSummary.contains("ramp"))
    }

    @Test("a payload the requester refuses up front reports no metrics")
    func refusedSendReportsNoMetrics() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        let outcome = SendOutcome()
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: 4096)),
            maxAcceptByteCount: 16, isInline: true, isCurrent: { _ in true },
            onComplete: { outcome.record($0) })

        try await outcome.gate.wait { outcome.succeeded != nil }
        #expect(outcome.succeeded == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("a superseded send reports no metrics")
    func supersededSendReportsNoMetrics() async throws {
        let harness = try harness()
        defer { harness.tearDown() }

        let outcome = SendOutcome()
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: 4096)),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in false },
            onComplete: { outcome.record($0) })

        try await outcome.gate.wait { outcome.succeeded != nil }
        #expect(outcome.succeeded == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("a send the peer aborts mid-stream reports no metrics")
    func peerAbortedSendReportsNoMetrics() async throws {
        // Acks are held back so the sender parks on credit, which is where the
        // peer's abort lands.
        let harness = try harness(suppressAcks: true)
        defer { harness.tearDown() }
        let once = OnceFlag()
        harness.onCreditWait = { [weak harness] transferID in
            guard once.claim() else { return }
            harness?.sender.handleAbort(transferID: transferID)
        }

        let outcome = SendOutcome()
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: Self.chunk * 2)),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true },
            onComplete: { outcome.record($0) })

        try await outcome.gate.wait { outcome.succeeded != nil }
        #expect(outcome.succeeded == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("a send that times out waiting for acks reports no metrics")
    func ackTimeoutSendReportsNoMetrics() async throws {
        // The timeout is the behavior under test, so a short one is correct.
        let harness = try harness(noAckTimeout: 0.2, suppressAcks: true)
        defer { harness.tearDown() }

        let outcome = SendOutcome()
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: Self.chunk * 2)),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true },
            onComplete: { outcome.record($0) })

        try await outcome.gate.wait { outcome.succeeded != nil }
        #expect(outcome.succeeded == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("every read from a source that runs behind is charged to the source wait")
    func sourceWaitAccumulatesOverReads() async throws {
        let clock = TestEngineClock()
        let bytes = incompressibleBytes(count: Self.chunk * 4)
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        // Real archive bytes, so the receiver's extract succeeds and the
        // transfer reaches its End rather than aborting.
        let archived = try clipboardArchiveBytes(ofFileAt: source, named: "big.bin")
        let stub = ClockAdvancingChunkReader(bytes: archived, clock: clock, secondsPerRead: 0.25)

        let harness = try harness(
            senderClock: clock, archiveSource: { _, _, _ in stub })
        defer { harness.tearDown() }

        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        #expect(stub.readCount > 1)
        #expect(sent.sourceWait == Double(stub.readCount) * 0.25)
        // The first read fills the first chunk whole, so the ramp is one read.
        #expect(sent.timeToFirstChunk == 0.25)
        // A frozen clock only moves inside a read, and no read runs while the
        // sender is waiting on credit.
        #expect(sent.creditStall == 0)
    }

    @Test("time parked waiting for credit is charged to the credit stall")
    func creditStallAccumulatesWhileParked() async throws {
        let clock = TestEngineClock()
        let harness = try harness(senderClock: clock, suppressAcks: true)
        defer { harness.tearDown() }

        // Fires on the transfer's queue with the stall reading already taken, so
        // the advance below is bracketed by the measurement rather than racing
        // the park. Only the first wait pays; every later one adds nothing,
        // which is what makes the total exact.
        let once = OnceFlag()
        harness.onCreditWait = { [weak harness] _ in
            guard once.claim() else { return }
            clock.advance(seconds: 0.5)
            harness?.releaseAcks()
        }

        let payload = Data(repeating: 0x3, count: Self.chunk * 3)
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: ClipboardContent.Representation(
                uti: "public.utf8-plain-text", data: payload),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.outboundMetrics.count == 1 }
        let metrics = try #require(harness.collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        #expect(sent.creditStall == 0.5)
        #expect(sent.timeToFirstChunk == 0.5)
        #expect(metrics.duration == 0.5)
        #expect(sent.sourceWait == 0)
        #expect(metrics.logSummary.contains("credit 0.500 s"))
        #expect(metrics.logSummary.contains("3 chunks"))
    }
}
