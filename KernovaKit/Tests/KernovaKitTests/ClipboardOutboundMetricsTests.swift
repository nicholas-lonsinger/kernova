import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The sender's own stage timings, over a real data connection.
@Suite("ClipboardOutboundMetrics")
struct ClipboardOutboundMetricsTests {
    /// How far a check on the sender's own thread moves the test clock, in the
    /// case that measures where a transfer's seconds are charged.
    private static let perCheckSeconds: TimeInterval = 0.25

    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "outbound-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    @Test("a raw inline send reports its own metrics, with the wire count left unstated")
    func rawInlineSendReportsMetrics() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        let payload = Data(repeating: 0x42, count: 2 * ClipboardStreamTuning.dataReadBufferBytes + 17)
        let transferID: UInt64 = 1
        let received = Box<ReceivedTransfer?>(nil)
        let served = AsyncGate()
        harness.outbox.serve(
            transferID: transferID, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: payload),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    received.value = try? receiveTransfer(fd: far)
                    served.notify()
                }
            },
            onComplete: { collector.sendFinished(transferID, success: $0) })

        try await collector.gate.wait { collector.outboundMetrics.count == 1 }
        let metrics = try #require(collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        #expect(metrics.transferID == transferID)
        #expect(metrics.uti == "public.utf8-plain-text")
        #expect(sent.isArchived == false)
        // Raw: the wire bytes *are* the payload, so the summary stays silent
        // about them.
        #expect(metrics.byteCount == payload.count)
        #expect(metrics.wireByteCount == payload.count)
        #expect(!metrics.logSummary.contains("wire bytes"))
        #expect(metrics.logSummary.contains("raw"))
        #expect(metrics.duration > .zero)
        let ramp = try #require(sent.timeToFirstByte)
        #expect(ramp <= metrics.duration)
        #expect(metrics.inbound == nil)

        // The wire count the peer was told matches what the sender counted.
        try await served.wait { received.value != nil }
        let transfer = try #require(received.value)
        #expect(Int(transfer.reply.totalBytes) == metrics.wireByteCount)
        #expect(transfer.payload == payload)
        #expect(transfer.isComplete)
        // The metrics are reported before the transfer's own terminal, so the
        // verdict is awaited rather than read off the wait above.
        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == true)
    }

    @Test("an archived file send counts the archive on the wire and the payload it expands to")
    func archivedFileSendReportsMetrics() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        let bytes = incompressibleBytes(count: 5 * ClipboardStreamTuning.dataReadBufferBytes + 99)
        let source = try tempFile(bytes: bytes)
        defer { try? fm.removeItem(at: source) }

        let transferID: UInt64 = 1
        harness.pull(
            transferID: transferID, generation: 1,
            plan: .init(uti: "public.data", filename: "big.bin", advertisedByteCount: bytes.count),
            representation: .init(
                uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin"))

        try await collector.gate.wait {
            collector.outboundMetrics.count == 1 && collector.inboundMetrics.count == 1
        }
        let metrics = try #require(collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)
        let received = try #require(collector.inboundMetrics.first)

        #expect(sent.isArchived)
        // Incompressible, so what separates the two counts is the container the
        // payload crossed in rather than anything the compressor did.
        #expect(metrics.wireByteCount != metrics.byteCount)
        // Both lines describe the same transfer, so both state the payload the
        // file expands to — not the archive stream that carried it.
        #expect(metrics.byteCount == bytes.count)
        #expect(received.byteCount == metrics.byteCount)
        #expect(received.wireByteCount == metrics.wireByteCount)
        #expect(metrics.logSummary.contains("archive"))
        #expect(metrics.logSummary.contains("\(metrics.wireByteCount) wire bytes"))
        #expect(collector.abortCount == 0)
    }

    @Test("a folder send reports metrics in the tree's unit")
    func folderSendReportsMetrics() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Project", isDirectory: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 256 * 1024)
            .write(to: source.appendingPathComponent("sub/big.log"))

        let transferID: UInt64 = 1
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        harness.pull(
            transferID: transferID, generation: 1,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "Project",
                extractsDirectoryNamed: "Project", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "Project"))

        try await collector.gate.wait {
            collector.outboundMetrics.count == 1 && collector.inboundMetrics.count == 1
        }
        let metrics = try #require(collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)
        let received = try #require(collector.inboundMetrics.first)

        #expect(sent.isArchived)
        #expect(metrics.wireByteCount < metrics.byteCount)
        #expect(received.wireByteCount == metrics.wireByteCount)
        // A folder is the one payload whose exact size is unknown while it
        // streams, so the sender states its uncompressed archive stream — the
        // tree plus its per-entry headers, at or above what the receiver counts.
        #expect(metrics.byteCount >= received.byteCount)
        #expect(collector.abortCount == 0)
    }

    @Test("a zero-byte send reports no ramp")
    func zeroByteSendReportsNoRamp() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        harness.push(
            transferID: 1, generation: 1, plan: .init(uti: "public.utf8-plain-text"),
            representation: .init(uti: "public.utf8-plain-text", data: Data()), isInline: true)

        try await collector.gate.wait { collector.outboundMetrics.count == 1 }
        let metrics = try #require(collector.outboundMetrics.first)
        let sent = try #require(metrics.outbound)

        // No byte was ever handed to the socket, so there is no first one to
        // date the ramp from.
        #expect(sent.timeToFirstByte == nil)
        #expect(metrics.byteCount == 0)
        #expect(metrics.wireByteCount == 0)
        #expect(!metrics.logSummary.contains("ramp"))
    }

    @Test("a payload the requester refuses up front reports no metrics")
    func refusedSendReportsNoMetrics() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        let transferID: UInt64 = 1
        harness.push(
            transferID: transferID, generation: 1,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: 4096),
            representation: .init(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: 4096)),
            isInline: true, maxAcceptByteCount: 16)

        try await collector.gate.wait { collector.sendCount == 1 && collector.abortCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)
        #expect(try #require(collector.abortInfos.first).code == .diskFull)
        #expect(collector.outboundMetrics.isEmpty)
    }

    @Test("a send superseded before its first byte reports no metrics")
    func supersededSendReportsNoMetrics() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        let transferID: UInt64 = 1
        harness.push(
            transferID: transferID, generation: 1,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: 4096),
            representation: .init(
                uti: "public.utf8-plain-text", data: Data(repeating: 0x7, count: 4096)),
            isInline: true, isCurrent: { _ in false })

        try await collector.gate.wait { collector.sendCount == 1 && collector.abortCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)
        #expect(try #require(collector.abortInfos.first).code == .superseded)
        #expect(collector.outboundMetrics.isEmpty)
    }

    @Test("a send the peer abandons mid-payload reports no metrics")
    func peerAbortedSendReportsNoMetrics() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector

        // Past every buffer in the pipeline, so the connection goes away with
        // most of the payload still to write.
        let payload = Data(repeating: 0x7, count: 8 * 1024 * 1024)
        let transferID: UInt64 = 1
        harness.outbox.serve(
            transferID: transferID, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: payload),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    // A peer's abort on a data connection is the connection
                    // going away under the payload.
                    _ = readTransferReply(fd: far)
                    ClipboardDataConnection.end(fd: far)
                }
            },
            onComplete: { collector.sendFinished(transferID, success: $0) })

        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)
        #expect(collector.outboundMetrics.isEmpty)
    }

    @Test("seconds spent producing bytes rather than handing them to the socket are the source's")
    func sourceWaitAccumulatesOverWrites() async throws {
        let clock = TestEngineClock()
        let timed = Box<[ClipboardTransferMetrics]>([])
        let reported = AsyncGate()
        let outbox = ClipboardTransferOutbox(
            role: .guest, clock: clock,
            onTransferTimed: { metrics in
                timed.value.append(metrics)
                reported.notify()
            })
        defer { outbox.cancelAll() }

        // The supersession check is the hook that runs on the sending thread
        // between a buffer being produced and the socket taking it, so the
        // seconds it burns are charged exactly where a slow source's are. It
        // runs once before the stream opens and once before every socket write.
        let checks = Box(0)
        let payload = Data(repeating: 0x42, count: 4 * ClipboardStreamTuning.dataReadBufferBytes)
        let transferID: UInt64 = 1
        outbox.serve(
            transferID: transferID, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: payload),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in
                checks.value += 1
                clock.advance(seconds: Self.perCheckSeconds)
                return true
            },
            link: .dial { try dialToPeer { far in _ = try? receiveTransfer(fd: far) } })

        try await reported.wait { !timed.value.isEmpty }
        let metrics = try #require(timed.value.first)
        let sent = try #require(metrics.outbound)

        // More than one write, so the figure accumulated over the stream rather
        // than being taken once.
        #expect(checks.value > 2)
        #expect(sent.sourceWait >= 2 * Self.perCheckSeconds)
        // A clock that moves nowhere else charges every second of the stream to
        // one stage or the other, and none of them was the socket's: what is left
        // over is the check before the stream opened.
        #expect(sent.sourceWait == metrics.duration - Self.perCheckSeconds)
        #expect(sent.timeToFirstByte == 2 * Self.perCheckSeconds)
    }
}
