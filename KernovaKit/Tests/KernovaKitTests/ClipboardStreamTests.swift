import CryptoKit
import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

@Suite("ClipboardStream")
struct ClipboardStreamTests {
    /// Small sizes so a handful of KiB exercises many chunks and several window
    /// refills.
    private static let chunk = 4096
    private static let window = 16384  // 4 chunks

    private func roomyHarness(noAckTimeout: TimeInterval = 10) throws -> StreamHarness {
        try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window, noAckTimeout: noAckTimeout,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })  // 100 GiB
    }

    /// Harness sized for the ack-coalescing tests.
    ///
    /// 1 KiB chunks under a 16 KiB window → a 4 KiB ack quantum (4 chunks), so
    /// a few KiB exercises several quantum boundaries. The ack latency bound is
    /// pushed out of reach so the expected ack schedules stay pure byte-quantum
    /// functions — deterministic even on a stalled CI scheduler.
    private func quantumHarness() throws -> StreamHarness {
        try StreamHarness(
            chunkSize: 1024, windowBytes: 16384, ackLatencyBound: 600,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
    }

    private func tempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    /// The priming a requester performs before its `ClipboardRequest` goes out,
    /// funnelling delivery into the harness collector.
    ///
    /// Every archived transfer — a file, a folder, an oversize inline payload —
    /// is refused at Begin unless a pull is awaiting it, and `advertised` is the
    /// figure its extract is held to.
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

    /// Announces an archived transfer, exactly as the sender does for one.
    private func beginArchive(
        _ harness: StreamHarness, id: UInt64, uti: String = "public.data",
        filename: String = "", isInline: Bool = false
    ) {
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = id
                $0.uti = uti
                $0.totalBytes = 0
                $0.filename = filename
                $0.isInline = isInline
                $0.isArchive = true
            })
    }

    /// Feeds `bytes` to a transfer in `chunkSize` slices, as the wire does.
    private func feed(
        _ harness: StreamHarness, id: UInt64, bytes: Data, chunkSize: Int = Self.chunk
    ) {
        var offset = 0
        while offset < bytes.count {
            let upper = min(offset + chunkSize, bytes.count)
            let slice = Data(bytes[bytes.startIndex + offset..<bytes.startIndex + upper])
            let at = offset
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(at)
                    $0.data = slice
                })
            offset = upper
        }
    }

    /// Closes a transfer with the End frame its wire bytes imply.
    private func endTransfer(_ harness: StreamHarness, id: UInt64, bytes: Data) {
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })
    }

    // MARK: - Round trips

    @Test("an inline multi-chunk payload round-trips on the macOS 12 fallback clock")
    func inlineRoundTripOnMonotonicClock() async throws {
        // Every other test in this suite runs the harness on the platform clock
        // — `ContinuousEngineClock` on a 13+ runner, the clock a host build
        // uses. This is the pass over the fallback conformance, so both real
        // clocks stream on every CI run.
        let harness = try StreamHarness(
            clock: MonotonicEngineClock(), chunkSize: Self.chunk, windowBytes: Self.window)
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 4 + 57) { bytes.append(UInt8((i * 17 + 3) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: bytes)

        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("an inline multi-chunk payload round-trips with identical bytes and digest")
    func inlineRoundTrip() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        // ~10 chunks of pseudo-random bytes.
        var bytes = Data()
        for i in 0..<(Self.chunk * 10 + 123) { bytes.append(UInt8((i * 31 + 7) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: bytes)

        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(received.uti == "public.utf8-plain-text")
        #expect(received.fileURL == nil)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("an inline payload larger than the 2 MiB window round-trips (exercises the inline reserve cap)")
    func largeInlineRoundTrip() async throws {
        // Production 64 KiB chunks + 1 MiB window; a ~3 MiB inline rep stays RAM-
        // resident (< maxResidentInlineBytes) and reassembles through the larger
        // reserve path — min(totalBytes, maxInlineReserveBytes) — rather than the
        // old 2 MiB window reserve. Also exercises the sender's slice-aliasing read.
        let harness = try StreamHarness(
            chunkSize: ClipboardStreamTuning.defaultChunkPayloadSize,
            windowBytes: ClipboardStreamTuning.defaultWindowBytes,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let count = 3 * 1024 * 1024 + 777  // > 2 MiB, deliberately not chunk-aligned
        let bytes = Data((0..<count).map { UInt8((($0 &* 31) &+ 7) & 0xFF) })
        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: bytes)

        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(received.fileURL == nil)  // stayed inline — no disk spill
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a file payload crosses as a one-entry archive and lands under its own name")
    func fileRoundTrip() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 7 + 50) { bytes.append(UInt8((i * 17 + 3) & 0xFF)) }
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin")

        prime(harness, id: 2, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 2, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(2) != nil }
        let received = try #require(harness.collector.representation(2))
        let url = try #require(received.fileURL)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(received.byteCount == bytes.count)
        #expect(received.filename == "big.bin")
        // The one entry keeps its exact name inside a scratch directory of its
        // own, under the staging root.
        #expect(url.lastPathComponent == "big.bin")
        #expect(harness.staging.isInStagingRoot(url))

        // The wire is the archive: no size is declared up front, and the count
        // and digest that close the transfer describe the archive rather than
        // the file.
        let begin = try #require(harness.collector.begin(2))
        #expect(begin.isArchive)
        #expect(begin.totalBytes == 0)
        let end = try #require(harness.collector.end(2))
        #expect(end.totalBytes > 0)
        guard case .file(_, _, let sha256) = received.source else {
            Issue.record("Expected a .file representation")
            return
        }
        #expect(sha256 == end.sha256)
        #expect(sha256 != Data(SHA256.hash(data: bytes)))
    }

    @Test("a zero-byte file round-trips as a one-entry archive carrying an empty entry")
    func zeroByteFileRoundTrip() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let source = try tempFile(bytes: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: 0, filename: "empty.bin")

        prime(harness, id: 3, advertised: 0)
        harness.sender.startTransfer(
            transferID: 3, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(3) != nil }
        let received = try #require(harness.collector.representation(3))
        let url = try #require(received.fileURL)
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(received.byteCount == 0)
        #expect(received.filename == "empty.bin")
        #expect(url.lastPathComponent == "empty.bin")
        // A file carrying no bytes still has an archive around it, so the wire
        // is never empty.
        let end = try #require(harness.collector.end(3))
        #expect(end.totalBytes > 0)
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == end.sha256)
        } else {
            Issue.record("Expected a .file representation")
        }
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a zero-byte inline payload round-trips raw: Begin, no chunks, the empty-input digest")
    func zeroByteInlineRoundTrip() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: Data())
        harness.sender.startTransfer(
            transferID: 3, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(3) != nil }
        let received = try #require(harness.collector.representation(3))
        #expect(received.inMemoryData == Data())
        #expect(received.fileURL == nil)
        let begin = try #require(harness.collector.begin(3))
        #expect(!begin.isArchive)
        let end = try #require(harness.collector.end(3))
        #expect(end.totalBytes == 0)
        #expect(end.sha256 == Data(SHA256.hash(data: Data())))
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a superseded zero-byte transfer delivers nothing and tells the peer")
    func supersededZeroByteTransferDeliversNothing() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: Data())

        // Every abort and supersession check used to sit inside the chunk loop,
        // which a zero-byte payload never enters — so an already-retired empty
        // transfer streamed and reported success anyway. `isCurrent` false at
        // run time is the deterministic stand-in for a newer copy landing in
        // the gap between registration and this transfer's queue.
        harness.sender.startTransfer(
            transferID: 4, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in false })

        try await harness.collector.gate.wait { harness.collector.abortCount == 1 }
        #expect(harness.collector.abortInfos.first?.code == "superseded")
        #expect(harness.collector.representation(4) == nil)
        #expect(harness.collector.completedCount == 0)
    }

    @Test("completed transfers report timing metrics for the throughput log line")
    func completedTransfersReportTimingMetrics() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        // One file rep (streams to disk) and one small inline rep (RAM).
        var bytes = Data()
        for i in 0..<(Self.chunk * 5 + 99) { bytes.append(UInt8((i * 13 + 5) & 0xFF)) }
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let fileRep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin")
        let inlineBytes = Data(repeating: 0x42, count: 512)
        let inlineRep = ClipboardContent.Representation(
            uti: "public.utf8-plain-text", data: inlineBytes)

        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: fileRep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })
        harness.sender.startTransfer(
            transferID: 2, generation: 1, representation: inlineRep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.completedCount == 2 }
        try await harness.collector.gate.wait { harness.collector.timedMetrics.count == 2 }

        let fileMetrics = try #require(
            harness.collector.timedMetrics.first { $0.transferID == 1 })
        // The logical payload is the file; the archive that carried it is the
        // wire count, and the summary names it only because the two differ.
        let fileEnd = try #require(harness.collector.end(1))
        #expect(fileMetrics.byteCount == bytes.count)
        #expect(fileMetrics.wireByteCount == Int(fileEnd.totalBytes))
        #expect(fileMetrics.wireByteCount != fileMetrics.byteCount)
        #expect(fileMetrics.logSummary.contains("\(fileMetrics.wireByteCount) wire bytes"))
        #expect(fileMetrics.uti == "public.data")
        #expect(fileMetrics.streamedToDisk)
        #expect(fileMetrics.duration > .zero)
        let streaming = try #require(fileMetrics.streamingDuration)
        #expect(streaming > .zero)
        #expect(streaming <= fileMetrics.duration)

        let inlineMetrics = try #require(
            harness.collector.timedMetrics.first { $0.transferID == 2 })
        #expect(inlineMetrics.byteCount == inlineBytes.count)
        // Raw: the wire bytes *are* the payload, so the summary stays silent
        // about them.
        #expect(inlineMetrics.wireByteCount == inlineBytes.count)
        #expect(!inlineMetrics.logSummary.contains("wire bytes"))
        #expect(!inlineMetrics.streamedToDisk)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a payload far larger than the old 104 MiB cap streams successfully")
    func exceedsOldCap() async throws {
        // Production 64 KiB chunks, 256 KiB window, ~105 MiB file rep — proves the
        // size cap is gone and the transfer never resides whole in memory.
        let harness = try StreamHarness(
            chunkSize: ClipboardStreamTuning.defaultChunkPayloadSize,
            windowBytes: ClipboardStreamTuning.defaultWindowBytes,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let size = 105 * 1024 * 1024  // > old 104 MiB total cap
        let pattern = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: source)
        var written = 0
        while written < size {
            let slice = pattern.prefix(min(pattern.count, size - written))
            try writeHandle.write(contentsOf: slice)
            written += slice.count
        }
        try writeHandle.close()
        defer { try? FileManager.default.removeItem(at: source) }

        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: size, filename: "huge.bin")
        prime(harness, id: 3, advertised: size)
        harness.sender.startTransfer(
            transferID: 3, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait(timeout: 60) {
            harness.collector.representation(3) != nil || harness.collector.abortCount > 0
        }
        #expect(harness.collector.abortInfos.map(\.code) == [])
        let received = try #require(harness.collector.representation(3))
        let url = try #require(received.fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as? Int) == size)
        #expect(received.byteCount == size)
        // The digest covers the archive that crossed, which for a repeating
        // pattern is a fraction of the file it unpacked to.
        let end = try #require(harness.collector.end(3))
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == end.sha256)
        }
        #expect(Int(end.totalBytes) < size)
    }

    @Test("two interleaved transfers are correlated by transfer_id")
    func interleavedTransfers() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let bytesA = Data((0..<(Self.chunk * 5)).map { UInt8(($0 * 3) & 0xFF) })
        let bytesB = Data((0..<(Self.chunk * 6 + 11)).map { UInt8(($0 * 5 + 1) & 0xFF) })

        harness.sender.startTransfer(
            transferID: 10, generation: 1,
            representation: .init(uti: "public.png", data: bytesA), maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })
        harness.sender.startTransfer(
            transferID: 11, generation: 1,
            representation: .init(uti: "public.tiff", data: bytesB), maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait {
            harness.collector.representation(10) != nil && harness.collector.representation(11) != nil
        }
        #expect(harness.collector.representation(10)?.inMemoryData == bytesA)
        #expect(harness.collector.representation(11)?.inMemoryData == bytesB)
    }

    @Test("a tiny window still completes a large transfer (backpressure)")
    func backpressureCompletes() async throws {
        // window == one chunk forces the sender to wait for an ack after every
        // chunk; the transfer must still complete with correct bytes.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.chunk,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data((0..<(Self.chunk * 20 + 5)).map { UInt8(($0 * 7) & 0xFF) })
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: .init(uti: "public.data", data: bytes), maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        #expect(harness.collector.representation(1)?.inMemoryData == bytes)
    }

    // MARK: - Ack coalescing (#377)

    @Test("acks are coalesced to the window/4 quantum, with a final ack at End")
    func acksCoalesceToQuantum() async throws {
        // 16 full chunks + a 500-byte tail must produce exactly the go-signal,
        // one ack per accumulated quantum, and the final tail ack at End — not
        // one ack per chunk. The schedule is deterministic: chunks land in
        // order on the transfer's serial queue, and the ack decision depends
        // only on the received/acked byte counts.
        let harness = try quantumHarness()
        defer { harness.tearDown() }

        let total = 16 * 1024 + 500
        let bytes = Data((0..<total).map { UInt8((($0 &* 31) &+ 7) & 0xFF) })
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: bytes),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        // The final ack travels the socket while completion is delivered
        // directly — wait for the ack too before asserting the schedule.
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(1).last == UInt64(total)
        }
        #expect(
            harness.collector.ackedByteCounts(1) == [0, 4096, 8192, 12288, 16384, UInt64(total)])
        #expect(harness.collector.representation(1)?.inMemoryData == bytes)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a transfer below one ack quantum acks only the go-signal and the tail at End")
    func belowQuantumAcksOnlyAtEnd() async throws {
        // Two 1 KiB-and-under chunks never accumulate the 4 KiB quantum, so no
        // mid-stream ack fires at all — only the go-signal and the final ack at
        // End, which must cover the whole payload (the sender's cumulative
        // credit ledger ends complete).
        let harness = try quantumHarness()
        defer { harness.tearDown() }

        let total = 1024 + 500
        let bytes = Data((0..<total).map { UInt8((($0 &* 17) &+ 3) & 0xFF) })
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: bytes),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(1).last == UInt64(total)
        }
        #expect(harness.collector.ackedByteCounts(1) == [0, UInt64(total)])
        #expect(harness.collector.representation(1)?.inMemoryData == bytes)
    }

    @Test("a stale last-ack forces an ack on the next chunk even below the byte quantum")
    func staleLastAckForcesAckBelowQuantum() async throws {
        // ackLatencyBound: 0 makes every landing chunk see a stale last-ack
        // (elapsed ≥ 0 always holds), deterministically forcing the
        // latency-bound path that the production 1 s value only takes under
        // degraded I/O — the guard that slow durable writes cannot stretch the
        // gap between credit-opening acks past the sender's fixed no-ack
        // deadline (#377).
        let harness = try StreamHarness(
            chunkSize: 1024, windowBytes: 16384, ackLatencyBound: 0,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let total = 3 * 1024
        let bytes = Data((0..<total).map { UInt8((($0 &* 11) &+ 5) & 0xFF) })
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: .init(uti: "public.utf8-plain-text", data: bytes),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(1).last == UInt64(total)
        }
        // Every chunk sits below the 4 KiB quantum, yet each one acks.
        #expect(harness.collector.ackedByteCounts(1) == [0, 1024, 2048, UInt64(total)])
        #expect(harness.collector.representation(1)?.inMemoryData == bytes)
    }

    @Test("a duplicate chunk below the ack quantum still re-acks immediately")
    func duplicateChunkReAcksBelowQuantum() async throws {
        // A duplicate means the peer may be out of sync — the re-ack stays
        // unconditional (never coalesced), carrying the durably-written count.
        let harness = try quantumHarness()
        defer { harness.tearDown() }

        let bytes = Data(repeating: 0x5A, count: 1024)
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 21; $0.uti = "public.data"
                $0.totalBytes = UInt64(bytes.count); $0.isInline = true
            })
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(21) == [0] }

        harness.receiver.handleChunk(
            .with {
                $0.transferID = 21; $0.offset = 0; $0.data = bytes
            })
        // 1 KiB < the 4 KiB quantum: the write itself acks nothing; only the
        // duplicate triggers the re-sync ack.
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 21; $0.offset = 0; $0.data = bytes
            })
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(21).count == 2
        }
        #expect(harness.collector.ackedByteCounts(21) == [0, 1024])

        // End finds the tail already acked by the duplicate's re-ack — the
        // transfer completes without a redundant final ack.
        harness.receiver.handleEnd(
            .with {
                $0.transferID = 21; $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })
        try await harness.collector.gate.wait { harness.collector.representation(21) != nil }
        #expect(harness.collector.ackedByteCounts(21) == [0, 1024])
    }

    // MARK: - Write-lane pipelining (#615)

    /// A harness whose archived transfers extract through a `GatedSink` the test
    /// releases by hand, plus the box that sink lands in once Begin opens it.
    ///
    /// The gate wraps the production extract sink and passes the receiver's own
    /// output guard through to it, so the ceiling and free-space checks still
    /// fire while the test owns when each write lands. The ack latency bound is
    /// pushed out of reach so every ack schedule below is a pure function of
    /// which writes the test released — never of how long a loaded CI runner
    /// took to run them.
    private func gatedHarness(freeSpace: @escaping @Sendable () -> Int64 = { 100 << 30 }) throws
        -> (harness: StreamHarness, sink: Box<GatedSink?>)
    {
        let sinkBox = Box<GatedSink?>(nil)
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            ackLatencyBound: 600,
            freeSpaceProvider: { _ in freeSpace() },
            sinkFactory: { destination, label, onOutputAdvanced in
                let sink = GatedSink(
                    wrapping: makeExtractSink(
                        destinationURL: destination, label: label, windowBytes: Self.window,
                        onOutputAdvanced: onOutputAdvanced))
                sinkBox.value = sink
                return sink
            })
        return (harness, sinkBox)
    }

    /// Opens an inbound archived transfer for an already-primed pull and waits
    /// for its go-signal ack, so the extract sink is open before the test drives
    /// chunks.
    private func openArchivedTransfer(
        _ harness: StreamHarness, id: UInt64, filename: String
    ) async throws {
        beginArchive(harness, id: id, filename: filename)
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id) == [0] }
    }

    /// Registers a per-transfer awaiter that forwards completion/abort to the
    /// harness collector and records cumulative received-byte progress.
    ///
    /// Progress is the receive lane's own signal — it fires per *accepted*
    /// chunk, before those bytes reach the sink — which is what makes the write
    /// lane's independence observable. A gated sink is not the extract sink the
    /// receiver would read an unpacked count from, so the figure recorded here
    /// is the wire count.
    private func trackProgress(_ harness: StreamHarness, _ id: UInt64, advertised: Int) -> (
        received: Box<Int>, gate: AsyncGate
    ) {
        let received = Box<Int>(0)
        let gate = AsyncGate()
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, advertisedByteCount: advertised,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) },
            onProgress: { bytes, _ in
                received.value = bytes
                gate.notify()
            })
        return (received, gate)
    }

    /// Random bytes drawn from `symbols` distinct values.
    ///
    /// The full alphabet is incompressible, so a payload's archive is about the
    /// size of the payload and the chunk framing a test picks is the framing it
    /// gets. A small alphabet compresses a few-fold instead, which is what puts
    /// many chunks on the wire for a progress readout to climb through.
    private func randomBytes(_ count: Int, symbols: Int = 256) -> Data {
        var generator = SystemRandomNumberGenerator()
        let highest = UInt8(clamping: max(2, symbols) - 1)
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<raw.count {
                base[index] = UInt8.random(in: 0...highest, using: &generator)
            }
        }
        return bytes
    }

    @Test("the receive lane keeps accepting and hashing chunks while every extract write is parked")
    func receiveLaneRunsAheadOfParkedWrites() async throws {
        // The point of #615: a chunk's staging write no longer sits between it
        // and the next chunk. With every write parked, every chunk must still be
        // validated, hashed, and progress-reported — while the ack ledger stays
        // at the go-signal, because credit still tracks only durably-written
        // bytes.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 601

        let payload = randomBytes(Self.chunk * 4)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "parked.bin")

        let progress = trackProgress(harness, id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "parked.bin")
        feed(harness, id: id, bytes: wire)

        try await progress.gate.wait { progress.received.value == wire.count }
        let sink = try #require(sinkBox.value)
        // Nothing has been made durable: the first write is parked in the gate
        // and the rest are queued behind it.
        #expect(sink.completedWrites == 0)
        #expect(harness.collector.ackedByteCounts(id) == [0])

        // Releasing the backlog completes the transfer with the right bytes.
        sink.allowAll()
        endTransfer(harness, id: id, bytes: wire)
        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let url = try #require(harness.collector.representation(id)?.fileURL)
        #expect(try Data(contentsOf: url) == payload)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("acks advance only as the write lane makes bytes durable, never as they arrive")
    func acksTrackDurableWritesNotArrivals() async throws {
        // A 4 KiB chunk under a 16 KiB window is exactly one ack quantum, so
        // each released write produces exactly one ack — the schedule is a pure
        // function of how many writes the test let through, and the chunks the
        // receiver has accepted but not written must contribute nothing. The
        // archive is fed as four whole chunks and left unfinished; what the
        // extract makes of them is another test's subject.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 602
        let chunkCount = 4
        let total = Self.chunk * chunkCount

        let payload = randomBytes(Self.chunk * 5)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "durable.bin")
        #expect(wire.count >= total)

        let progress = trackProgress(harness, id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "durable.bin")
        feed(harness, id: id, bytes: Data(wire.prefix(total)))
        try await progress.gate.wait { progress.received.value == total }
        let sink = try #require(sinkBox.value)

        sink.allow(2)
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id).count == 3 }
        // All four chunks are in — only the two written ones are acked.
        #expect(harness.collector.ackedByteCounts(id) == [0, 4096, 8192])
        #expect(sink.completedWrites == 2)
        #expect(progress.received.value == total)

        sink.allowAll()
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id).count == 5 }
        #expect(harness.collector.ackedByteCounts(id) == [0, 4096, 8192, 12288, 16384])
        // Unwind the extract pipeline this transfer never finished feeding.
        harness.receiver.cancel(generation: 1)
    }

    @Test("End completes only once the write backlog has drained and committed")
    func endWaitsForTheWriteBacklog() async throws {
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 603

        let payload = randomBytes(Self.chunk * 3)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "drain.bin")
        let chunkCount = (wire.count + Self.chunk - 1) / Self.chunk

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "drain.bin")
        feed(harness, id: id, bytes: wire)
        let sink = try #require(sinkBox.value)
        sink.allow(chunkCount - 1)
        endTransfer(harness, id: id, bytes: wire)

        // Wait until the write lane is parked *inside* the last chunk's write.
        // The completion barrier is queued behind that write, so while it is
        // parked nothing can have been committed or delivered — no settling
        // delay needed to make the negative assertion sound.
        try await sink.gate.wait {
            sink.startedWrites == chunkCount && sink.completedWrites == chunkCount - 1
        }
        #expect(harness.collector.completedCount == 0)
        #expect(harness.collector.abortCount == 0)

        sink.allowAll()
        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let received = try #require(harness.collector.representation(id))
        let url = try #require(received.fileURL)
        #expect(try Data(contentsOf: url) == payload)
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == Data(SHA256.hash(data: wire)))
        } else {
            Issue.record("Expected a .file representation")
        }
    }

    @Test("an extract write that fails mid-backlog aborts the transfer and deletes the partial")
    func writeErrorMidBacklogAborts() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 << 30 },
            sinkFactory: { destination, label, onOutputAdvanced in
                FailingSink(
                    wrapping: makeExtractSink(
                        destinationURL: destination, label: label, windowBytes: Self.window,
                        onOutputAdvanced: onOutputAdvanced),
                    failingWrite: 2)
            })
        defer { harness.tearDown() }
        let id: UInt64 = 604

        let payload = randomBytes(Self.chunk * 3)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "failing.bin")

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "failing.bin")
        feed(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        // The sink names its own failure, and the sink is an extract.
        #expect(harness.collector.abortInfos.contains { $0.code == "extract.error" })
        #expect(harness.collector.representation(id) == nil)
        // Timing metrics report successful transfers only.
        #expect(harness.collector.timedMetrics.isEmpty)
        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`)
        // — the partial's deletion runs on the write lane after the abort has
        // already been delivered, so there is no test-owned signal to gate on.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("an extract refusing bytes past its drop bound aborts the transfer as an overrun")
    func writeRefusedPastTheDropBoundAborts() async throws {
        // Where a peer that streams a whole valid archive and then keeps sending
        // chunks without an End frame lands: the extract has already unpacked
        // everything, drops the tail up to its bound, and refuses past it. The
        // refusal is injected rather than streamed, because how much of that
        // tail AppleArchive's decompressor buffers before the pipeline exits is
        // its business, not this receiver's — the bound itself is covered by
        // `ClipboardArchiveStreamTests`.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 << 30 },
            sinkFactory: { destination, label, onOutputAdvanced in
                FailingSink(
                    wrapping: makeExtractSink(
                        destinationURL: destination, label: label, windowBytes: Self.window,
                        onOutputAdvanced: onOutputAdvanced),
                    failingWrite: 2, throwing: ClipboardArchiveStreamError.streamClosed)
            })
        defer { harness.tearDown() }
        let id: UInt64 = 605

        let payload = randomBytes(Self.chunk * 3)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "overrun.bin")

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "overrun.bin")
        feed(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        // Named as the overrun it is: the extract itself succeeded, so
        // `extract.error` would send the user off retrying a good transfer.
        #expect(harness.collector.abortInfos.contains { $0.code == "size.overrun" })
        #expect(harness.collector.representation(id) == nil)
    }

    @Test("a sink that silently drops archive bytes fails the extract instead of delivering a truncated payload")
    func droppedArchiveBytesAreCaughtAtCommit() async throws {
        // The digest is taken over the bytes that *arrive*, so a sink that
        // accepts a chunk without storing it sails through both the size and
        // SHA-256 checks — the receive lane counted those bytes. What catches it
        // is the extract: an archive missing a chunk cannot be unpacked
        // (CLIPBOARD.md §7).
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 << 30 },
            sinkFactory: { destination, label, onOutputAdvanced in
                SilentlyDroppingSink(
                    wrapping: makeExtractSink(
                        destinationURL: destination, label: label, windowBytes: Self.window,
                        onOutputAdvanced: onOutputAdvanced),
                    droppingWrite: 2)
            })
        defer { harness.tearDown() }
        let id: UInt64 = 608

        let payload = randomBytes(Self.chunk * 3)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "short.bin")

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "short.bin")
        feed(harness, id: id, bytes: wire)
        // Correct total, correct digest — both computed over what arrived.
        endTransfer(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "extract.error" })
        #expect(harness.collector.representation(id) == nil)
        #expect(harness.collector.timedMetrics.isEmpty)
        // A streamed extract has always written part of its output by the time
        // anything can be verified, so the failure takes it with it.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a transfer torn down with a write backlog still deletes its partial")
    func teardownWithWriteBacklogDeletesPartial() async throws {
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 605

        let payload = randomBytes(Self.chunk * 4)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "superseded.bin")

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "superseded.bin")
        feed(harness, id: id, bytes: Data(wire.prefix(Self.chunk * 3)))
        let sink = try #require(sinkBox.value)
        // Pin the lane inside the first write, so the teardown below lands with
        // a genuine backlog queued behind it.
        try await sink.gate.wait { sink.startedWrites == 1 }

        harness.receiver.cancel(generation: 1)
        // The cleanup is ordered behind the parked write, exactly as a real slow
        // volume would order it; releasing lets the lane drain into the abort.
        sink.allowAll()

        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`)
        // — supersession is silent on the channel-wide path, so no collector
        // signal fires for it.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
        #expect(harness.collector.representation(id) == nil)
    }

    @Test("a peer that ignores the credit window is cut off before its backlog can grow")
    func backlogOverrunAborts() async throws {
        // The receive lane never blocks — it hands each chunk to the write lane
        // and returns — so a peer that ignores the window would otherwise queue
        // chunks on a parked lane until the heap ran out.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 707
        let ceiling = ClipboardStreamTuning.maxBacklogBytes(forWindowBytes: Self.window)
        // An archive declares no total, so the backlog bound is the only thing
        // holding this stream to anything.
        prime(harness, id: id, advertised: ceiling * 4)
        try await openArchivedTransfer(harness, id: id, filename: "flood.bin")

        // The gated sink parks the write lane, so nothing drains the backlog.
        let flood = Data(repeating: 0x11, count: ClipboardStreamTuning.maxChunkBytes / 2)
        var offset = 0
        while offset <= ceiling {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(offset)
                    $0.data = flood
                })
            offset += flood.count
        }

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "flow.overrun")
        try #require(sinkBox.value).allowAll()
    }

    @Test("a volume that fills mid-stream aborts from the extract guard with disk.full")
    func midStreamDiskFullOnWriteLane() async throws {
        // Roomy at Begin, then nearly full: the extract's own guard — paced by
        // the payload it writes, not by the archive arriving — must catch it and
        // abort cleanly, naming what the offer said the payload needs.
        let free = Box<Int64>(100 << 30)
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in free.value })
        defer { harness.tearDown() }
        let id: UInt64 = 606

        // Compressible, so the whole archive is a fraction of a window while the
        // file it unpacks to is many windows long.
        let payload = Data(repeating: 0x5E, count: 512 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "filling.bin")

        prime(harness, id: id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "filling.bin")
        free.value = 1024
        feed(harness, id: id, bytes: wire)
        endTransfer(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(info.neededBytes == payload.count)
        #expect(harness.collector.representation(id) == nil)
    }

    @Test("a duplicate chunk on the disk path re-acks the durably-written count, not the received one")
    func duplicateOnDiskPathReAcksDurableCount() async throws {
        // Sub-quantum chunks so no write of its own triggers an ack: the only
        // mid-stream ack is the duplicate's, which must report the bytes the
        // sink has taken (1 KiB) rather than the bytes accepted off the wire
        // (2 KiB) — the whole point of routing it through the write lane.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 607
        let piece = 1024

        let payload = randomBytes(8 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "dup.bin")
        #expect(wire.count > 2 * piece)

        let progress = trackProgress(harness, id, advertised: payload.count)
        try await openArchivedTransfer(harness, id: id, filename: "dup.bin")

        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = 0; $0.data = wire.prefix(piece)
            })
        // Duplicate of chunk 0 — its re-ack queues behind chunk 0's write.
        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = 0; $0.data = wire.prefix(piece)
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = UInt64(piece)
                $0.data = wire[(wire.startIndex + piece)..<(wire.startIndex + 2 * piece)]
            })

        // Both real chunks are accepted before any write is released, so
        // `receivedBytes` is already the full 2 KiB when the re-ack runs.
        try await progress.gate.wait { progress.received.value == 2 * piece }
        let sink = try #require(sinkBox.value)
        sink.allow(1)

        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id).count == 2 }
        #expect(harness.collector.ackedByteCounts(id) == [0, UInt64(piece)])

        sink.allowAll()
        var offset = 2 * piece
        while offset < wire.count {
            let upper = min(offset + piece, wire.count)
            let slice = Data(wire[(wire.startIndex + offset)..<(wire.startIndex + upper)])
            let at = offset
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id; $0.offset = UInt64(at); $0.data = slice
                })
            offset = upper
        }
        endTransfer(harness, id: id, bytes: wire)
        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let url = try #require(harness.collector.representation(id)?.fileURL)
        #expect(try Data(contentsOf: url) == payload)
    }

    // MARK: - Receiver robustness (driven directly)

    @Test("a duplicate chunk is ignored and the transfer still completes")
    func duplicateChunkIgnored() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let c0 = Data(repeating: 0xA1, count: Self.chunk)
        let c1 = Data(repeating: 0xB2, count: 100)
        let all = c0 + c1
        let digest = Data(SHA256.hash(data: all))

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = 99
                $0.uti = "public.data"
                $0.totalBytes = UInt64(all.count)
                $0.isInline = true
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 99; $0.offset = 0; $0.data = c0
            })
        // Duplicate of chunk 0 — must be ignored, not double-counted.
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 99; $0.offset = 0; $0.data = c0
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 99; $0.offset = UInt64(c0.count); $0.data = c1
            })
        harness.receiver.handleEnd(
            .with {
                $0.transferID = 99; $0.totalBytes = UInt64(all.count); $0.sha256 = digest
            })

        try await harness.collector.gate.wait { harness.collector.representation(99) != nil }
        #expect(harness.collector.representation(99)?.inMemoryData == all)
    }

    @Test("an out-of-order (gapped) chunk aborts the transfer")
    func gappedChunkAborts() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = 7
                $0.uti = "public.data"
                $0.totalBytes = 8192
                $0.isInline = true
            })
        // Skip offset 0; send offset 4096 → gap.
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 7; $0.offset = 4096; $0.data = Data(repeating: 1, count: 4096)
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.representation(7) == nil)
        #expect(harness.collector.abortInfos.contains { $0.code == "offset.gap" })
    }

    @Test("cancelling a generation deletes the in-flight partial extract")
    func cancelDeletesPartial() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 1

        let payload = randomBytes(512 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "partial.bin")

        // Every byte but the End frame: the extract has written the entry and
        // the transfer is still in flight, which is the state a supersession
        // has to clean up after.
        prime(harness, id: id, advertised: payload.count)
        beginArchive(harness, id: id, filename: "partial.bin")
        feed(harness, id: id, bytes: wire)

        // RATIONALE: Filesystem-appearance polls with no gate-able signal. The
        // receiver extracts into (and deletes) the staging destination on its
        // private per-transfer DispatchQueue; the only test-owned signal
        // (StreamCollector.gate) fires on onComplete/onAbort, never on partial
        // I/O. Per docs/TESTING.md "Async waits in tests", a filesystem-appearance poll is
        // a sanctioned `waitUntil` use.
        // The partial is written off the transfer queue.
        try await waitUntil {
            materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "partial.bin"
            }
        }
        // A superseding cancel deletes the partial rather than leaking it.
        harness.receiver.cancel(generation: 1)
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
        #expect(harness.collector.representation(id) == nil)
    }

    @Test("an orphan chunk for an unknown transfer is ignored")
    func orphanChunkIgnored() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 12345; $0.offset = 0; $0.data = Data([1, 2, 3])
            })
        // Nothing should complete or abort.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.collector.completedCount == 0)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a size mismatch at End aborts the transfer")
    func sizeMismatchAborts() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let bytes = Data(repeating: 0xEE, count: 4096)
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 5; $0.uti = "public.data"
                $0.totalBytes = 8192; $0.isInline = true
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 5; $0.offset = 0; $0.data = bytes
            })
        // Claim 8192 but only 4096 arrived.
        harness.receiver.handleEnd(
            .with {
                $0.transferID = 5; $0.totalBytes = 8192
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "size.mismatch" })
    }

    @Test("a digest mismatch at End aborts the transfer")
    func digestMismatchAborts() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        let bytes = Data(repeating: 0x11, count: 4096)
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 6; $0.uti = "public.data"
                $0.totalBytes = UInt64(bytes.count); $0.isInline = true
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 6; $0.offset = 0; $0.data = bytes
            })
        harness.receiver.handleEnd(
            .with {
                $0.transferID = 6; $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(repeating: 0xFF, count: 32)  // wrong digest
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "digest.mismatch" })
        #expect(harness.collector.representation(6) == nil)
        // Timing metrics report successful transfers only.
        #expect(harness.collector.timedMetrics.isEmpty)
    }

    // MARK: - Free-space guard

    @Test("a file rep that exceeds free space is rejected with disk.full")
    func diskFullRejected() async throws {
        // 10 MiB free; a 50 MiB file rep can't be staged.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 10 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data(count: 50 * 1024 * 1024)
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin")

        // The pull advertised the file's size, which is the figure the volume is
        // measured against — the archive's own size is unknown until its last
        // byte.
        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(info.neededBytes == bytes.count)
        #expect(harness.collector.representation(1) == nil)
    }

    // MARK: - What may cross raw

    @Test("a raw Begin declaring more than fits in memory is refused")
    func absurdBeginTotalRejected() async throws {
        // 100 GiB free: nothing local makes this fail — the declared total does.
        // Raw is how a peer sends what the receiver can hold resident, and
        // nothing else, so `UInt64.max` has to be refused at Begin rather than
        // reach arithmetic that kills the process or a buffer that grows without
        // bound.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 9; $0.uti = "public.data"
                $0.totalBytes = .max; $0.isInline = true; $0.filename = "absurd.bin"
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.unsupported")
        #expect(harness.collector.representation(9) == nil)
    }

    @Test("a raw Begin that is not inline is refused")
    func nonInlineRawBeginRejected() async throws {
        // A payload that lands on disk crosses as an archive; raw bytes claiming
        // otherwise have no sink to stream into.
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 10; $0.uti = "public.data"
                $0.totalBytes = 4096; $0.isInline = false; $0.filename = "raw.bin"
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.unsupported")
        #expect(harness.collector.representation(10) == nil)
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("a raw inline Begin answering a folder pull is refused")
    func rawBeginForAPrimedFolderRejected() async throws {
        // The requester primed a folder; a peer claiming a small inline payload
        // must not have that request answered with bytes in RAM.
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        prime(harness, id: 12, advertised: 4096, extractsDirectoryNamed: "Folder")

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 12; $0.uti = "public.folder"
                $0.totalBytes = 16; $0.isInline = true; $0.filename = "Folder"
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.unsupported")
        #expect(harness.collector.representation(12) == nil)
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("an archived Begin nobody is awaiting is refused before anything is staged")
    func unawaitedArchiveBeginRejected() async throws {
        // An archive carries neither a name to unpack it under nor a size to
        // hold it to — both ride the pull that asked for it.
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        beginArchive(harness, id: 11, filename: "unasked.bin")

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.unexpected")
        #expect(harness.collector.representation(11) == nil)
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("a file's extract ceiling is its advertised size plus one entry's allowance")
    func fileExtractCeilingIsTighterThanAFolders() throws {
        // A file's advertised size is exact, so its slack is the entry header's;
        // a folder's is a stat-walk estimate that the archive's per-entry
        // headers sit on top of, so its ceiling doubles and never falls below
        // the floor.
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let advertised = 1024

        #expect(
            harness.receiver.extractCeiling(forAdvertisedByteCount: advertised, isDirectory: false)
                == advertised + ClipboardStreamTuning.fileExtractAllowance)
        #expect(
            harness.receiver.extractCeiling(forAdvertisedByteCount: advertised, isDirectory: true)
                == ClipboardStreamTuning.minimumExtractAllowance)
        #expect(
            harness.receiver.extractCeiling(
                forAdvertisedByteCount: 128 << 20, isDirectory: true) == 256 << 20)
    }

    @Test("a file that unpacks past what its offer advertised is refused")
    func fileExtractIsHeldToTheAdvertisedSize() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 12

        // Two megabytes against a kilobyte offer: more than the one-entry
        // allowance covers, so the guard fires while the file is being written.
        let payload = Data(repeating: 0x7B, count: 2 * 1024 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "overrun.bin")

        prime(harness, id: id, advertised: 1024)
        beginArchive(harness, id: id, filename: "overrun.bin")
        feed(harness, id: id, bytes: wire)
        endTransfer(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "size.overrun")
        #expect(harness.collector.representation(id) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the partial
        // output is removed on the write lane after the abort is delivered.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a file that unpacks to more than its offer said, within the header allowance, is still refused")
    func fileExtractIsHeldToTheAdvertisedSizeExactly() async throws {
        // The allowance is for the entry header, not for payload: a peer must
        // not get to spend it on bytes the offer never declared.
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 13

        let payload = Data(repeating: 0x2A, count: 4096 + 512)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "padded.bin")

        prime(harness, id: id, advertised: 4096)
        beginArchive(harness, id: id, filename: "padded.bin")
        feed(harness, id: id, bytes: wire)
        endTransfer(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "size.overrun")
        #expect(harness.collector.representation(id) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the output
        // is removed on the write lane after the abort is delivered.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("an archive unpacking to more than one file is refused as a payload that was never offered")
    func multiEntryArchiveForAFileIsRefused() async throws {
        // A file's archive holds exactly one regular-file entry. A tree arriving
        // for a pull that never primed a folder name is a payload that does not
        // match what the offer described.
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 13

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "multi-entry-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try Data("one".utf8).write(to: scratch.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: scratch.appendingPathComponent("b.txt"))
        let wire = try clipboardArchiveBytes(ofDirectoryAt: scratch)

        prime(harness, id: id, advertised: 4096)
        beginArchive(harness, id: id, filename: "a.txt")
        feed(harness, id: id, bytes: wire)
        endTransfer(harness, id: id, bytes: wire)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.invalid")
        #expect(harness.collector.representation(id) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the rejected
        // extract is removed after the abort is delivered.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    // MARK: - Liveness & untrusted-input bounds

    @Test("a sender whose peer never acks aborts with ack.timeout")
    func noAckTimesOut() async throws {
        // The harness drops every ack, so the sender never gets the go-signal
        // and the no-ack deadline must fire.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            noAckTimeout: 0.2, suppressAcks: true,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data((0..<(Self.chunk * 4)).map { UInt8($0 & 0xFF) })
        harness.sender.startTransfer(
            transferID: 1, generation: 1,
            representation: .init(uti: "public.data", data: bytes), maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "ack.timeout" })
        #expect(harness.collector.representation(1) == nil)
    }

    @Test("a receiver whose sender stops after Begin aborts with stall.timeout")
    func inboundStallTimesOut() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            stallTimeout: 0.15,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        prime(harness, id: 1, advertised: 1_000_000)
        beginArchive(harness, id: 1, filename: "stalled.bin")
        // No chunks ever arrive — the inactivity deadline must abort and clean up.
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "stall.timeout" })
        #expect(harness.collector.representation(1) == nil)
        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`).
        // Since #615 the partial is deleted on the transfer's write lane, so the
        // abort this test just observed is delivered *before* the deletion runs
        // — deliberately, so a wedged write can't delay waking a blocked pull.
        // There is no test-owned signal for the deletion itself.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a sender that goes silent after streaming chunks aborts with stall.timeout")
    func midStreamStallTimesOut() async throws {
        // The watchdog is one repeating timer anchored on the last chunk's
        // arrival (#377), not a per-chunk re-armed one-shot — prove it keeps
        // watching *after* activity, not just after Begin.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            stallTimeout: 0.15,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let payload = randomBytes(512 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "mid-stall.bin")

        prime(harness, id: 8, advertised: payload.count)
        beginArchive(harness, id: 8, filename: "mid-stall.bin")
        feed(harness, id: 8, bytes: Data(wire.prefix(Self.chunk)))
        // One chunk landed, then silence — the watchdog must still fire and
        // clean up the partial.
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "stall.timeout" })
        #expect(harness.collector.representation(8) == nil)
        // RATIONALE: filesystem-appearance poll — see `inboundStallTimesOut`.
        // The partial's deletion runs on the write lane, after the abort.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("each arriving chunk advances the stall watchdog's activity anchor")
    func chunkAdvancesStallAnchor() async throws {
        // Deterministic seam check (no timing): the watchdog compares against
        // `lastChunkAt`, so each arriving chunk must move the anchor forward —
        // this is what replaced the per-chunk timer re-arm (#377). The roomy
        // harness's quantum-sized chunks (4 KiB chunk, 16 KiB window → 4 KiB
        // quantum) make every chunk emit an ack to gate on, so each anchor read
        // is ordered after its chunk's receive-lane block.
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 31; $0.uti = "public.data"
                $0.totalBytes = 16384; $0.isInline = true
            })
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(31) == [0] }
        let anchorAtBegin = try #require(harness.receiver.lastChunkAtForTesting(31))

        harness.receiver.handleChunk(
            .with {
                $0.transferID = 31; $0.offset = 0; $0.data = Data(repeating: 1, count: 4096)
            })
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(31).count == 2
        }
        let anchorAfterFirst = try #require(harness.receiver.lastChunkAtForTesting(31))
        #expect(anchorAfterFirst > anchorAtBegin)

        harness.receiver.handleChunk(
            .with {
                $0.transferID = 31; $0.offset = 4096; $0.data = Data(repeating: 2, count: 4096)
            })
        try await harness.collector.gate.wait {
            harness.collector.ackedByteCounts(31).count == 3
        }
        let anchorAfterSecond = try #require(harness.receiver.lastChunkAtForTesting(31))
        #expect(anchorAfterSecond > anchorAfterFirst)
    }

    @Test("an inline rep past the residency threshold crosses archived, then mmaps back identically")
    func inlineSpillsAboveThreshold() async throws {
        // Tiny residency threshold so a few KiB exercises the spill path without
        // moving 256 MiB. The rep is inline (no filename) — the large-image case
        // — and must round-trip byte-identical via the memory-mapped read.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 8192,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 6 + 77) { bytes.append(UInt8((i * 53 + 11) & 0xFF)) }
        #expect(bytes.count > 8192)  // above the threshold → must spill
        let rep = ClipboardContent.Representation(uti: "public.png", data: bytes)

        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        // Delivered as a resident `.inMemory` payload (mmap is transparent), bytes
        // and flavor preserved — no inline.too.large, no downgrade to a file rep.
        #expect(received.inMemoryData == bytes)
        #expect(received.fileURL == nil)
        #expect(received.uti == "public.png")
        #expect(harness.collector.abortCount == 0)
        // It crossed as an archive while still asking to be delivered inline.
        let begin = try #require(harness.collector.begin(1))
        #expect(begin.isArchive)
        #expect(begin.isInline)
        #expect(begin.totalBytes == 0)
        // It really spilled: a staging file backs the mapping.
        #expect(!materializedFiles(under: harness.stagingTempRoot).isEmpty)
        // The digest is byte-based (tag 0), identical to the same bytes assembled
        // in memory — so echo suppression still recognizes round-tripped content.
        let inMemory = ClipboardContent.Representation(uti: "public.png", data: bytes)
        #expect(
            ClipboardContent(representations: [received]).digest
                == ClipboardContent(representations: [inMemory]).digest)
    }

    @Test("an inline rep at/below the residency threshold stays in RAM (no staging file)")
    func inlineBelowThresholdStaysResident() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 1 << 20,  // 1 MiB
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 4) { bytes.append(UInt8((i * 13 + 5) & 0xFF)) }  // ~16 KiB
        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: bytes)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(try #require(harness.collector.begin(1)).isArchive == false)
        #expect(harness.collector.abortCount == 0)
        // Stayed resident: nothing was staged to disk.
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("an inline file rep at/below the threshold crosses raw and arrives as resident bytes")
    func inlineFileBelowThresholdCrossesRaw() async throws {
        // An inline payload is resident bytes on both ends, so a file small
        // enough to hold is read here rather than streamed from disk — the
        // pasteboard flavor the receiver serves is unchanged either way.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 1 << 20,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data((0..<(Self.chunk * 3)).map { UInt8((($0 &* 41) &+ 13) & 0xFF) })
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.png", fileURL: source, byteCount: bytes.count, filename: "")

        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(received.fileURL == nil)
        let begin = try #require(harness.collector.begin(1))
        #expect(!begin.isArchive)
        #expect(begin.totalBytes == UInt64(bytes.count))
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("an inline file rep above the threshold crosses archived and arrives byte-identical")
    func inlineFileAboveThresholdCrossesArchived() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 8192,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data((0..<(Self.chunk * 5 + 31)).map { UInt8((($0 &* 47) &+ 9) & 0xFF) })
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.png", fileURL: source, byteCount: bytes.count, filename: "")

        prime(harness, id: 1, advertised: bytes.count)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        // Still an inline flavor: the extract's one entry is mapped back rather
        // than offered as a file URL.
        #expect(received.inMemoryData == bytes)
        #expect(received.fileURL == nil)
        let begin = try #require(harness.collector.begin(1))
        #expect(begin.isArchive)
        #expect(begin.isInline)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("a spilled inline transfer cancelled mid-stream deletes its partial")
    func spilledInlineCancelDeletesPartial() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 4096,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }
        let id: UInt64 = 1

        // An oversize inline rep crosses as an archive like any other spilled
        // payload; drive Begin and its bytes but no End, so the transfer is left
        // in flight over an extract that has already written.
        let payload = randomBytes(512 * 1024)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let wire = try clipboardArchiveBytes(ofFileAt: source, named: "image.png")

        prime(harness, id: id, advertised: payload.count)
        beginArchive(harness, id: id, uti: "public.png", isInline: true)
        feed(harness, id: id, bytes: wire)
        // The sink was created and a partial written.
        try await waitUntil { !materializedFiles(under: harness.stagingTempRoot).isEmpty }
        // Supersede the generation: the spilled partial must be deleted, exactly
        // like a file rep's.
        harness.receiver.cancel(generation: 1)
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a chunk past the declared total is rejected with size.overrun")
    func overrunRejected() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 1; $0.uti = "public.data"
                $0.totalBytes = 10; $0.isInline = true
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 1; $0.offset = 0; $0.data = Data(repeating: 0xAB, count: 100)
            })
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "size.overrun" })
        #expect(harness.collector.representation(1) == nil)
    }

    // MARK: - Rejecting a request without starting a transfer (#357)

    @Test("rejectRequest emits a well-formed Abort the receiver delivers with no Begin")
    func rejectRequestEmitsAbort() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        // No Begin/transfer is ever started: rejectRequest models a side dropping
        // a request it won't answer (stale generation / out-of-range / UTI
        // mismatch) and aborting so the requester's parked pull wakes immediately
        // instead of stalling to its lazyPullTimeout. With no awaiter registered,
        // the abort surfaces on the channel-wide onAbort (the collector).
        let transferID = ClipboardTransferID.make(generation: 4, repIndex: 1, hostMinted: false)
        harness.sender.rejectRequest(
            transferID: transferID, code: "request.stale", message: "superseded")

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.transferID == transferID)
        #expect(info.code == "request.stale")
        #expect(info.message == "superseded")
        #expect(harness.collector.completedCount == 0)
    }

    @Test("rejectRequest wakes a registered awaiter (the parked pull) for that id")
    func rejectRequestWakesAwaiter() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        // The awaiter stands in for the per-transfer handler a blocked lazy pull
        // registers; it must fire even though no Begin ever arrives for the id.
        let transferID = ClipboardTransferID.make(generation: 8, repIndex: 0, hostMinted: false)
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: { collector.complete(transferID, $0) },
            onAbort: { collector.abort($0) })

        harness.sender.rejectRequest(
            transferID: transferID, code: "request.uti", message: "uti mismatch")

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "request.uti")
        #expect(harness.collector.completedCount == 0)
    }

    // MARK: - Sender progress

    /// `Sendable` recorder for the sender's `onProgress`/`onComplete` callbacks.
    private final class SenderProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sentValues: [Int] = []
        private var totalSeen = 0
        private var completedSuccess: Bool?
        let gate = AsyncGate()

        func progress(sent: Int, total: Int) {
            lock.withLock {
                sentValues.append(sent)
                totalSeen = total
            }
        }
        func complete(_ success: Bool) {
            lock.withLock { completedSuccess = success }
            gate.notify()
        }
        var sent: [Int] { lock.withLock { sentValues } }
        var total: Int { lock.withLock { totalSeen } }
        var completion: Bool? { lock.withLock { completedSuccess } }
    }

    @Test("startTransfer reports monotonic byte progress and completes successfully")
    func senderReportsProgressAndCompletes() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 5 + 99) { bytes.append(UInt8((i * 13 + 5) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: "public.utf8-plain-text", data: bytes)

        let recorder = SenderProgressRecorder()
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true },
            onProgress: { sent, total in recorder.progress(sent: sent, total: total) },
            onComplete: { success in recorder.complete(success) })

        try await recorder.gate.wait { recorder.completion != nil }
        #expect(recorder.completion == true)
        let sent = recorder.sent
        #expect(!sent.isEmpty)
        #expect(sent == sent.sorted())  // non-decreasing
        #expect(sent.last == bytes.count)  // final == total
        #expect(recorder.total == bytes.count)  // total constant across callbacks
        #expect(harness.collector.abortCount == 0)
    }

    @Test("an archived file reports progress in payload bytes on both ends, with no total")
    func archivedFileReportsProgressInPayloadBytes() async throws {
        // Every readout's denominator is the offer's figure — the file's own
        // size — so a numerator counting compressed wire bytes crawls to a
        // fraction and then snaps, which reads as a hung paste. Both ends report
        // what the archive holds, not what the wire carried, and an archive
        // declares no total so the tracker keeps the offer's.
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 71

        // A four-symbol alphabet compresses several-fold, so the wire count is
        // well below the file's — a readout that slipped back to it would be
        // unmistakable — while still putting many chunks on the wire for both
        // readouts to climb through.
        let payload = randomBytes(4 * 1024 * 1024, symbols: 4)
        let source = try tempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: payload.count, filename: "log.txt")

        let recorder = SenderProgressRecorder()
        let received = Box(0)
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, advertisedByteCount: payload.count,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) },
            onProgress: { bytes, _ in received.value = max(received.value, bytes) })
        harness.sender.startTransfer(
            transferID: id, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true },
            onProgress: { sent, total in recorder.progress(sent: sent, total: total) },
            onComplete: { success in recorder.complete(success) })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        try await recorder.gate.wait { recorder.completion != nil }
        let wireByteCount = Int(try #require(harness.collector.end(id)).totalBytes)
        #expect(wireByteCount < payload.count)

        let sent = recorder.sent
        #expect(sent == sent.sorted())  // non-decreasing
        // The archive's own container is the only thing above the file's bytes.
        let last = try #require(sent.last)
        #expect(last >= payload.count)
        #expect(last <= payload.count + ClipboardStreamTuning.fileExtractAllowance)
        #expect(recorder.total == 0)
        // The receiver reports what the extract has written, which likewise
        // outruns the compressed count long before the transfer ends.
        #expect(received.value > wireByteCount)
        #expect(received.value <= payload.count + ClipboardStreamTuning.fileExtractAllowance)
    }

    @Test("startTransfer fires onComplete(false) when the requester can't accept the payload")
    func senderCompletesFalseOnRefusal() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 3) { bytes.append(UInt8(i & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: "public.data", data: bytes)

        let recorder = SenderProgressRecorder()
        // A ceiling below the payload size → refused up front with Abort{disk.full}
        // before any Begin/chunk, so onComplete(false) fires and onProgress never does.
        harness.sender.startTransfer(
            transferID: 2, generation: 1, representation: rep,
            maxAcceptByteCount: UInt64(bytes.count - 1),
            isInline: false, isCurrent: { _ in true },
            onProgress: { sent, total in recorder.progress(sent: sent, total: total) },
            onComplete: { success in recorder.complete(success) })

        try await recorder.gate.wait { recorder.completion != nil }
        #expect(recorder.completion == false)
        #expect(recorder.sent.isEmpty)
    }
}
