import CryptoKit
import Foundation
import Testing

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
        // I/O. Per CLAUDE.md "Async waits in tests", a filesystem-appearance poll is
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
        #expect(
            !materializedFiles(under: harness.stagingTempRoot).contains {
                $0.lastPathComponent == "stalled.bin"
            })
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
