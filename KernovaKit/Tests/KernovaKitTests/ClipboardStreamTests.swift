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

    private func roomyHarness(noAckTimeout: Duration = .seconds(10)) throws -> StreamHarness {
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
            chunkSize: 1024, windowBytes: 16384, ackLatencyBound: .seconds(600),
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
    }

    private func tempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Round trips

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

    @Test("a file payload round-trips to a temp file with the streamed sha256")
    func fileRoundTrip() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        var bytes = Data()
        for i in 0..<(Self.chunk * 7 + 50) { bytes.append(UInt8((i * 17 + 3) & 0xFF)) }
        let expectedDigest = Data(SHA256.hash(data: bytes))
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "big.bin")

        harness.sender.startTransfer(
            transferID: 2, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(2) != nil }
        let received = try #require(harness.collector.representation(2))
        let url = try #require(received.fileURL)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(received.byteCount == bytes.count)
        #expect(received.filename == "big.bin")
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == expectedDigest)
        } else {
            Issue.record("Expected a .file representation")
        }
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
        #expect(fileMetrics.byteCount == bytes.count)
        #expect(fileMetrics.uti == "public.data")
        #expect(fileMetrics.streamedToDisk)
        #expect(fileMetrics.duration > .zero)
        let streaming = try #require(fileMetrics.streamingDuration)
        #expect(streaming > .zero)
        #expect(streaming <= fileMetrics.duration)

        let inlineMetrics = try #require(
            harness.collector.timedMetrics.first { $0.transferID == 2 })
        #expect(inlineMetrics.byteCount == inlineBytes.count)
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
        let expectedDigest: Data = {
            var hasher = SHA256()
            if let h = try? FileHandle(forReadingFrom: source) {
                while let block = try? h.read(upToCount: 1 << 20), !block.isEmpty {
                    hasher.update(data: block)
                }
                try? h.close()
            }
            return Data(hasher.finalize())
        }()

        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: size, filename: "huge.bin")
        harness.sender.startTransfer(
            transferID: 3, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait(timeout: .seconds(60)) {
            harness.collector.representation(3) != nil || harness.collector.abortCount > 0
        }
        let received = try #require(harness.collector.representation(3))
        let url = try #require(received.fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as? Int) == size)
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == expectedDigest)
        }
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
        // ackLatencyBound: .zero makes every landing chunk see a stale last-ack
        // (elapsed ≥ 0 always holds), deterministically forcing the
        // latency-bound path that the production 1 s value only takes under
        // degraded I/O — the guard that slow durable writes cannot stretch the
        // gap between credit-opening acks past the sender's fixed no-ack
        // deadline (#377).
        let harness = try StreamHarness(
            chunkSize: 1024, windowBytes: 16384, ackLatencyBound: .zero,
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

    /// A harness whose disk-streamed transfers append through a `GatedSink` the
    /// test releases by hand, plus the box that sink lands in once Begin opens
    /// it.
    ///
    /// The ack latency bound is pushed out of reach so every ack schedule below
    /// is a pure function of which writes the test released — never of how long
    /// a loaded CI runner took to run them.
    private func gatedHarness(freeSpace: @escaping @Sendable () -> Int64 = { 100 << 30 }) throws
        -> (harness: StreamHarness, sink: Box<GatedSink?>)
    {
        let stagingBox = Box<ClipboardFileStaging?>(nil)
        let sinkBox = Box<GatedSink?>(nil)
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            ackLatencyBound: .seconds(600),
            freeSpaceProvider: { _ in freeSpace() },
            sinkFactory: { generation, filename in
                guard let staging = stagingBox.value else {
                    throw StreamTestFailure("Sink requested before the harness was wired")
                }
                let sink = GatedSink(
                    wrapping: try staging.makeSink(generation: generation, filename: filename))
                sinkBox.value = sink
                return sink
            })
        // Set before any transfer can begin — the factory runs on `handleBegin`.
        stagingBox.value = harness.staging
        return (harness, sinkBox)
    }

    /// Opens an inbound file transfer of `totalBytes` and waits for its
    /// go-signal ack, so the staging sink is open before the test drives chunks.
    private func beginFileTransfer(
        _ harness: StreamHarness, id: UInt64, totalBytes: Int, filename: String
    ) async throws {
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = id; $0.uti = "public.data"
                $0.totalBytes = UInt64(totalBytes); $0.isInline = false; $0.filename = filename
            })
        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id) == [0] }
    }

    /// Registers a per-transfer awaiter that forwards completion/abort to the
    /// harness collector and records cumulative received-byte progress.
    ///
    /// Progress is the receive lane's own signal — it fires per *accepted*
    /// chunk, before those bytes reach the sink — which is what makes the write
    /// lane's independence observable.
    private func trackProgress(_ harness: StreamHarness, _ id: UInt64) -> (
        received: Box<Int>, gate: AsyncGate
    ) {
        let received = Box<Int>(0)
        let gate = AsyncGate()
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) },
            onProgress: { bytes, _ in
                received.value = bytes
                gate.notify()
            })
        return (received, gate)
    }

    @Test("the receive lane keeps accepting and hashing chunks while every staging write is parked")
    func receiveLaneRunsAheadOfParkedWrites() async throws {
        // The point of #615: a chunk's staging write no longer sits between it
        // and the next chunk. With every write parked, all four chunks must
        // still be validated, hashed, and progress-reported — while the ack
        // ledger stays at the go-signal, because credit still tracks only
        // durably-written bytes.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 601
        let chunkCount = 4
        let total = Self.chunk * chunkCount

        let progress = trackProgress(harness, id)
        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "parked.bin")

        let bytes = Data((0..<total).map { UInt8((($0 &* 29) &+ 3) & 0xFF) })
        for i in 0..<chunkCount {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = bytes[(i * Self.chunk)..<((i + 1) * Self.chunk)]
                })
        }

        try await progress.gate.wait { progress.received.value == total }
        let sink = try #require(sinkBox.value)
        // Nothing has been made durable: the first write is parked in the gate
        // and the rest are queued behind it.
        #expect(sink.completedWrites == 0)
        #expect(harness.collector.ackedByteCounts(id) == [0])

        // Releasing the backlog completes the transfer with the right bytes.
        sink.allowAll()
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id; $0.totalBytes = UInt64(total)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })
        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let url = try #require(harness.collector.representation(id)?.fileURL)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("acks advance only as the write lane makes bytes durable, never as they arrive")
    func acksTrackDurableWritesNotArrivals() async throws {
        // A 4 KiB chunk under a 16 KiB window is exactly one ack quantum, so
        // each released write produces exactly one ack — the schedule is a pure
        // function of how many writes the test let through, and the chunks the
        // receiver has accepted but not written must contribute nothing.
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 602
        let chunkCount = 4
        let total = Self.chunk * chunkCount

        let progress = trackProgress(harness, id)
        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "durable.bin")
        for i in 0..<chunkCount {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = Data(repeating: UInt8(i), count: Self.chunk)
                })
        }
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
    }

    @Test("End completes only once the write backlog has drained and committed")
    func endWaitsForTheWriteBacklog() async throws {
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 603
        let chunkCount = 4
        let total = Self.chunk * chunkCount
        let bytes = Data((0..<total).map { UInt8((($0 &* 37) &+ 11) & 0xFF) })

        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "drain.bin")
        for i in 0..<chunkCount {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = bytes[(i * Self.chunk)..<((i + 1) * Self.chunk)]
                })
        }
        let sink = try #require(sinkBox.value)
        sink.allow(chunkCount - 1)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id; $0.totalBytes = UInt64(total)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

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
        #expect(try Data(contentsOf: url) == bytes)
        if case .file(_, _, let sha256) = received.source {
            #expect(sha256 == Data(SHA256.hash(data: bytes)))
        } else {
            Issue.record("Expected a .file representation")
        }
    }

    @Test("a staging write that fails mid-backlog aborts the transfer and deletes the partial")
    func writeErrorMidBacklogAborts() async throws {
        let stagingBox = Box<ClipboardFileStaging?>(nil)
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 << 30 },
            sinkFactory: { generation, filename in
                guard let staging = stagingBox.value else {
                    throw StreamTestFailure("Sink requested before the harness was wired")
                }
                return FailingSink(
                    wrapping: try staging.makeSink(generation: generation, filename: filename),
                    failingWrite: 2)
            })
        defer { harness.tearDown() }
        stagingBox.value = harness.staging
        let id: UInt64 = 604

        try await beginFileTransfer(
            harness, id: id, totalBytes: Self.chunk * 3, filename: "failing.bin")
        for i in 0..<3 {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = Data(repeating: UInt8(i), count: Self.chunk)
                })
        }

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "write.error" })
        #expect(harness.collector.representation(id) == nil)
        // Timing metrics report successful transfers only.
        #expect(harness.collector.timedMetrics.isEmpty)
        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`)
        // — the partial's deletion runs on the write lane after the abort has
        // already been delivered, so there is no test-owned signal to gate on.
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "failing.bin"
            }
        }
    }

    @Test("a staging sink that silently short-writes is caught at End instead of committing a truncated file")
    func shortWriteIsCaughtAtEnd() async throws {
        // The digest is taken over the bytes that *arrive*, so a sink that
        // accepts a chunk without storing it would sail through both the size
        // and SHA-256 checks — the receive lane counted those bytes. Only the
        // written-vs-expected comparison catches it (CLIPBOARD.md §7).
        let stagingBox = Box<ClipboardFileStaging?>(nil)
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            freeSpaceProvider: { _ in 100 << 30 },
            sinkFactory: { generation, filename in
                guard let staging = stagingBox.value else {
                    throw StreamTestFailure("Sink requested before the harness was wired")
                }
                return SilentlyDroppingSink(
                    wrapping: try staging.makeSink(generation: generation, filename: filename),
                    droppingWrite: 2)
            })
        defer { harness.tearDown() }
        stagingBox.value = harness.staging
        let id: UInt64 = 608
        let total = Self.chunk * 3
        let bytes = Data((0..<total).map { UInt8((($0 &* 23) &+ 5) & 0xFF) })

        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "short.bin")
        for i in 0..<3 {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = bytes[(i * Self.chunk)..<((i + 1) * Self.chunk)]
                })
        }
        // Correct total, correct digest — both computed over what arrived.
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id; $0.totalBytes = UInt64(total)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "write.short" })
        #expect(harness.collector.representation(id) == nil)
        #expect(harness.collector.timedMetrics.isEmpty)
        // The truncated file was already committed when the size check caught
        // it, so `Sink.abort()` can no longer remove it — the check deletes it
        // itself, synchronously, before the abort this test just observed.
        #expect(
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "short.bin"
            })
    }

    @Test("a transfer torn down with a write backlog still deletes its partial")
    func teardownWithWriteBacklogDeletesPartial() async throws {
        let (harness, sinkBox) = try gatedHarness()
        defer { harness.tearDown() }
        let id: UInt64 = 605

        try await beginFileTransfer(
            harness, id: id, totalBytes: 1_000_000, filename: "superseded.bin")
        for i in 0..<3 {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = Data(repeating: 0xC3, count: Self.chunk)
                })
        }
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
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "superseded.bin"
            }
        }
        #expect(harness.collector.representation(id) == nil)
    }

    @Test("a volume that fills mid-stream aborts from the write lane with disk.full")
    func midStreamDiskFullOnWriteLane() async throws {
        // Roomy at Begin, then nearly full: the write lane's once-per-window
        // re-check (keyed on written bytes) must catch it and abort cleanly.
        let free = Box<Int64>(100 << 30)
        let (harness, sinkBox) = try gatedHarness(freeSpace: { free.value })
        defer { harness.tearDown() }
        let id: UInt64 = 606
        let total = Self.chunk * 6

        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "filling.bin")
        free.value = 1024

        // Four chunks == one full window of written bytes, which is when the
        // re-check fires, with bytes still outstanding.
        for i in 0..<4 {
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(i * Self.chunk)
                    $0.data = Data(repeating: 0x5E, count: Self.chunk)
                })
        }
        try #require(sinkBox.value).allowAll()

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(info.neededBytes == total)
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
        let total = piece * 2
        let bytes = Data((0..<total).map { UInt8((($0 &* 19) &+ 7) & 0xFF) })

        let progress = trackProgress(harness, id)
        try await beginFileTransfer(harness, id: id, totalBytes: total, filename: "dup.bin")

        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = 0; $0.data = bytes.prefix(piece)
            })
        // Duplicate of chunk 0 — its re-ack queues behind chunk 0's write.
        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = 0; $0.data = bytes.prefix(piece)
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = UInt64(piece); $0.data = bytes.suffix(piece)
            })

        // Both real chunks are accepted before any write is released, so
        // `receivedBytes` is already the full 2 KiB when the re-ack runs.
        try await progress.gate.wait { progress.received.value == total }
        let sink = try #require(sinkBox.value)
        sink.allow(1)

        try await harness.collector.gate.wait { harness.collector.ackedByteCounts(id).count == 2 }
        #expect(harness.collector.ackedByteCounts(id) == [0, UInt64(piece)])

        sink.allowAll()
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id; $0.totalBytes = UInt64(total)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })
        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        #expect(try Data(contentsOf: #require(harness.collector.representation(id)?.fileURL)) == bytes)
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

    @Test("cancelling a generation deletes the in-flight partial temp file")
    func cancelDeletesPartial() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = 1
                $0.uti = "public.data"
                $0.totalBytes = 1_000_000
                $0.isInline = false
                $0.filename = "partial.bin"
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 1; $0.offset = 0; $0.data = Data(count: Self.chunk)
            })

        // RATIONALE: Filesystem-appearance polls with no gate-able signal. The
        // receiver creates and deletes the staging partial on its private
        // per-transfer DispatchQueue; the only test-owned signal
        // (StreamCollector.gate) fires on onComplete/onAbort, never on partial-file
        // I/O. Per docs/TESTING.md "Async waits in tests", a filesystem-appearance poll is
        // a sanctioned `pollUntil` use.
        // The partial temp file is created off the transfer queue.
        try await pollUntil {
            materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "partial.bin"
            }
        }
        // A superseding cancel deletes the partial rather than leaking it.
        harness.receiver.cancel(generation: 1)
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "partial.bin"
            }
        }
        #expect(harness.collector.representation(1) == nil)
    }

    @Test("a child-layout transfer_id round-trips a listing payload and a child file")
    func childLayoutTransferRoundTrips() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }

        // The tree listing rides an inline transfer with childSeq 0.
        let listingID = ClipboardTransferID.makeChild(
            generation: 3, repIndex: 0, childSeq: 0, hostMinted: false)
        let listingBytes = Data((0..<(Self.chunk * 2 + 9)).map { UInt8(($0 &* 13) & 0xFF) })
        harness.sender.startTransfer(
            transferID: listingID, generation: 3,
            representation: ClipboardContent.Representation(
                uti: "app.kernova.clipboard.tree-listing", data: listingBytes),
            maxAcceptByteCount: .max, isInline: true, isCurrent: { _ in true })

        // A child file rides a file transfer with childSeq >= 1.
        let childID = ClipboardTransferID.makeChild(
            generation: 3, repIndex: 0, childSeq: 1, hostMinted: false)
        let childBytes = Data((0..<(Self.chunk * 3 + 5)).map { UInt8(($0 &* 7) & 0xFF) })
        let source = try tempFile(bytes: childBytes)
        defer { try? FileManager.default.removeItem(at: source) }
        harness.sender.startTransfer(
            transferID: childID, generation: 3,
            representation: ClipboardContent.Representation(
                uti: "public.data", fileURL: source, byteCount: childBytes.count, filename: "c.bin"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait {
            harness.collector.representation(listingID) != nil
                && harness.collector.representation(childID) != nil
        }
        #expect(harness.collector.representation(listingID)?.inMemoryData == listingBytes)
        let child = try #require(harness.collector.representation(childID))
        #expect(child.fileURL != nil)
        #expect(try Data(contentsOf: #require(child.fileURL)) == childBytes)
        #expect(harness.collector.abortCount == 0)
    }

    @Test("cancel(generation:) cancels an in-flight child-layout transfer")
    func cancelGenerationCancelsChildTransfer() async throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        // A large offer generation forces the child layout's own generation field
        // (not the legacy bit position); cancel must still match it.
        let generation: UInt64 = 5
        let childID = ClipboardTransferID.makeChild(
            generation: generation, repIndex: 0, childSeq: 9, hostMinted: false)
        harness.receiver.handleBegin(
            .with {
                $0.generation = generation
                $0.transferID = childID
                $0.uti = "public.data"
                $0.totalBytes = 1_000_000
                $0.isInline = false
                $0.filename = "childpartial.bin"
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = childID; $0.offset = 0; $0.data = Data(count: Self.chunk)
            })
        try await pollUntil {
            materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "childpartial.bin"
            }
        }
        harness.receiver.cancel(generation: generation)
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "childpartial.bin"
            }
        }
        #expect(harness.collector.representation(childID) == nil)
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

        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(info.neededBytes == bytes.count)
        #expect(harness.collector.representation(1) == nil)
    }

    // MARK: - Liveness & untrusted-input bounds

    @Test("a sender whose peer never acks aborts with ack.timeout")
    func noAckTimesOut() async throws {
        // The harness drops every ack, so the sender never gets the go-signal
        // and the no-ack deadline must fire.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            noAckTimeout: .milliseconds(200), suppressAcks: true,
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
            stallTimeout: .milliseconds(150),
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 1; $0.uti = "public.data"
                $0.totalBytes = 1_000_000; $0.isInline = false; $0.filename = "stalled.bin"
            })
        // No chunks ever arrive — the inactivity deadline must abort and clean up.
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "stall.timeout" })
        #expect(harness.collector.representation(1) == nil)
        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`).
        // Since #615 the partial is deleted on the transfer's write lane, so the
        // abort this test just observed is delivered *before* the deletion runs
        // — deliberately, so a wedged write can't delay waking a blocked pull.
        // There is no test-owned signal for the deletion itself.
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "stalled.bin"
            }
        }
    }

    @Test("a sender that goes silent after streaming chunks aborts with stall.timeout")
    func midStreamStallTimesOut() async throws {
        // The watchdog is one repeating timer anchored on the last chunk's
        // arrival (#377), not a per-chunk re-armed one-shot — prove it keeps
        // watching *after* activity, not just after Begin.
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            stallTimeout: .milliseconds(150),
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 8; $0.uti = "public.data"
                $0.totalBytes = 1_000_000; $0.isInline = false; $0.filename = "mid-stall.bin"
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 8; $0.offset = 0
                $0.data = Data(repeating: 0x7C, count: Self.chunk)
            })
        // One chunk landed, then silence — the watchdog must still fire and
        // clean up the partial.
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.contains { $0.code == "stall.timeout" })
        #expect(harness.collector.representation(8) == nil)
        // RATIONALE: filesystem-appearance poll — see `inboundStallTimesOut`.
        // The partial's deletion runs on the write lane, after the abort.
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "mid-stall.bin"
            }
        }
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

    @Test("an inline rep past the residency threshold spills to disk, then mmaps back identically")
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
        #expect(harness.collector.abortCount == 0)
        // Stayed resident: nothing was staged to disk.
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("a spilled inline transfer cancelled mid-stream deletes its partial staging file")
    func spilledInlineCancelDeletesPartial() async throws {
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            maxResidentInlineBytes: 4096,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        // An inline rep declaring more than the threshold spills to a staging
        // sink; drive Begin + one partial chunk directly so the transfer is left
        // in flight.
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1; $0.transferID = 1; $0.uti = "public.png"
                $0.totalBytes = 1_000_000; $0.isInline = true
            })
        harness.receiver.handleChunk(
            .with {
                $0.transferID = 1; $0.offset = 0
                $0.data = Data(repeating: 0xAB, count: Self.chunk)
            })
        // The sink was created and a partial written.
        try await pollUntil { !materializedFiles(under: harness.stagingTempRoot).isEmpty }
        // Supersede the generation: the spilled partial must be deleted, exactly
        // like a file rep's.
        harness.receiver.cancel(generation: 1)
        try await pollUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    // MARK: - Consumer-requested cancel (#464)

    @Test(
        "cancel(transferID:) aborts the sender's in-flight transfer, deletes the receiver's partial, and wakes its awaiter"
    )
    func cancelTransferIDAbortsSenderAndReceiver() async throws {
        // `suppressAcks: true` deterministically parks the sender: it opens the
        // file, sends Begin, and then blocks in `awaitCredit` forever waiting for
        // the go-signal ack the harness never delivers — no race against a fast
        // in-process transfer completing on its own before this test intervenes
        // (unlike throttling by payload size alone, which a loopback socketpair
        // can race through in well under a millisecond).
        let harness = try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window, suppressAcks: true,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let bytes = Data(repeating: 0xCD, count: Self.chunk * 4)
        let source = try tempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "cancel-me.bin")

        let recorder = SenderProgressRecorder()
        let transferID: UInt64 = 42

        // Register a per-transfer awaiter — mirrors production usage (every real
        // caller of `cancel(transferID:)` operates on a transfer a
        // `LazyPullCoordinator`-backed pull registered via `awaitTransfer` before
        // sending its request). `cancel(transferID:)`, like `cancel(generation:)`/
        // `cancelAll()`, notifies only a registered awaiter and stays silent on
        // the channel-wide `onAbort` (supersession/teardown is never a
        // user-visible abort on that path) — so this test must not expect
        // `harness.collector` to observe anything.
        let abortBox = Box<ClipboardStreamAbortInfo?>(nil)
        let awaiterGate = AsyncGate()
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: { _ in Issue.record("onComplete should never fire — the transfer is cancelled") },
            onAbort: { info in
                abortBox.value = info
                awaiterGate.notify()
            })

        harness.sender.startTransfer(
            transferID: transferID, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true },
            onComplete: { success in recorder.complete(success) })

        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`
        // above) — proves the receiver's staging sink for this transfer exists
        // (Begin has landed) before this test intervenes.
        try await pollUntil {
            materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "cancel-me.bin"
            }
        }

        harness.receiver.cancel(transferID: transferID)

        // The harness's routing task delivers the abort frame to the sender
        // exactly like a real peer would — proving the sender genuinely stops
        // (rather than eventually hitting its own no-ack backstop), not just
        // that the receiver tore down its own local state.
        try await recorder.gate.wait { recorder.completion != nil }
        #expect(recorder.completion == false)

        try await awaiterGate.wait { abortBox.value != nil }
        #expect(abortBox.value?.code == "cancelled")
        // RATIONALE: filesystem-appearance poll (mirrors `cancelDeletesPartial`
        // above) — the partial's deletion has no test-owned signal to gate on
        // (the awaiter's `onAbort`, already awaited above, fires before
        // `teardown` deletes the file on its own transfer queue).
        try await pollUntil {
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "cancel-me.bin"
            }
        }
    }

    @Test("cancel(transferID:) for an unknown transfer is a harmless no-op")
    func cancelUnknownTransferIDIsNoOp() throws {
        let harness = try roomyHarness()
        defer { harness.tearDown() }
        // No Begin, no awaiter — must not crash or affect anything else.
        harness.receiver.cancel(transferID: 999_999)
        #expect(harness.collector.abortCount == 0)
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
