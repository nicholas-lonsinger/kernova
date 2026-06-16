import CryptoKit
import Foundation
import Testing

@testable import KernovaProtocol

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
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: 0,
            isInline: true, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(1) != nil }
        let received = try #require(harness.collector.representation(1))
        #expect(received.inMemoryData == bytes)
        #expect(received.uti == "public.utf8-plain-text")
        #expect(received.fileURL == nil)
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
            transferID: 2, generation: 1, representation: rep, maxAcceptByteCount: 0,
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
            transferID: 3, generation: 1, representation: rep, maxAcceptByteCount: 0,
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
            representation: .init(uti: "public.png", data: bytesA), maxAcceptByteCount: 0,
            isInline: true, isCurrent: { _ in true })
        harness.sender.startTransfer(
            transferID: 11, generation: 1,
            representation: .init(uti: "public.tiff", data: bytesB), maxAcceptByteCount: 0,
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
            representation: .init(uti: "public.data", data: bytes), maxAcceptByteCount: 0,
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
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: 0,
            isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(info.neededBytes == bytes.count)
        #expect(harness.collector.representation(1) == nil)
    }
}
