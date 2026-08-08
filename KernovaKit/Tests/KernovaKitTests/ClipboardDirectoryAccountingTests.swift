import CryptoKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What a folder transfer is measured in.
///
/// Its wire bytes are compressed and its tree is not, and LZFSE reaches ~100:1
/// on text — so every guard and every readout that reasons about "how big is
/// this" has to be expressed in the tree's unit, not the wire's. These are the
/// tests that fail when one of them slips back to counting wire bytes.
@Suite("ClipboardDirectoryAccounting")
struct ClipboardDirectoryAccountingTests {
    private static let chunk = 4096
    private static let window = 16384

    private func makeScratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "diraccounting-\(UUID().uuidString)", isDirectory: true)
    }

    /// A tree whose archive is a fraction of the tree it unpacks to.
    ///
    /// `symbols` is how many distinct byte values the content draws from. One is
    /// maximally compressible — a whole tree in a couple of KiB, which is what
    /// makes a wire-paced guard miss entirely. A small alphabet compresses a
    /// few-fold instead, which is what puts many chunks on the wire for the
    /// progress tests to observe.
    private func makeCompressibleTree(uncompressedBytes: Int, symbols: Int = 1) throws -> (
        scratch: URL, source: URL
    ) {
        let fm = FileManager.default
        let scratch = makeScratch()
        let source = scratch.appendingPathComponent("Logs", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let content: Data
        if symbols <= 1 {
            content = Data(repeating: 0x20, count: uncompressedBytes)
        } else {
            var generator = SystemRandomNumberGenerator()
            var bytes = Data(count: uncompressedBytes)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<raw.count {
                    base[index] = UInt8.random(in: 0..<UInt8(symbols), using: &generator)
                }
            }
            content = bytes
        }
        try content.write(to: source.appendingPathComponent("big.log"))
        return (scratch, source)
    }

    private func harness(
        freeSpace: @escaping @Sendable () -> Int64 = { 100 << 30 },
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance
    ) throws -> StreamHarness {
        try StreamHarness(
            chunkSize: Self.chunk, windowBytes: Self.window,
            minimumExtractAllowance: minimumExtractAllowance,
            freeSpaceProvider: { _ in freeSpace() })
    }

    private func prime(
        _ harness: StreamHarness, id: UInt64, named name: String, advertised: Int
    ) {
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, extractsDirectoryNamed: name, advertisedByteCount: advertised,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) })
    }

    private func begin(_ harness: StreamHarness, id: UInt64, named name: String) {
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = id
                $0.uti = ClipboardDirectoryArchive.directoryUTI
                $0.totalBytes = 0
                $0.filename = name
                $0.isInline = false
            })
    }

    private func archiveBytes(of source: URL) throws -> Data {
        let reader = ClipboardDirectoryArchiveReader(directoryURL: source, label: "test")
        var bytes = Data()
        while true {
            let chunk = try reader.read(upTo: 64 << 10)
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        return bytes
    }

    private func feed(_ harness: StreamHarness, id: UInt64, bytes: Data) {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.chunk, bytes.count)
            let slice = Data(bytes[bytes.startIndex + offset..<bytes.startIndex + end])
            harness.receiver.handleChunk(
                .with {
                    $0.transferID = id
                    $0.offset = UInt64(offset)
                    $0.data = slice
                })
            offset = end
        }
    }

    @Test("a volume that fills is caught while the tree is being written, not per wire byte")
    func diskGuardIsPacedByTheTreeNotTheWire() async throws {
        let fm = FileManager.default
        // Below the free-space margin, so any check that actually runs refuses.
        let harness = try harness(freeSpace: { 1024 })
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 512 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)
        // The point: this archive is far smaller than one credit window, so a
        // guard clocked on arriving wire bytes never fires at all, while the tree
        // it writes is many windows long.
        #expect(bytes.count < Self.window)

        let id: UInt64 = 61
        prime(harness, id: id, named: "Logs", advertised: 512 * 1024)
        begin(harness, id: id, named: "Logs")
        feed(harness, id: id, bytes: bytes)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        #expect(harness.collector.representation(id) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the tree is
        // removed on the write lane after the abort is delivered.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a folder that unpacks past what its offer advertised is refused")
    func extractIsHeldToTheAdvertisedSize() async throws {
        let fm = FileManager.default
        // A small allowance so the floor doesn't swallow the test; the floor's
        // production value exists for byte-free trees, not for this shape.
        let harness = try harness(minimumExtractAllowance: 4096)
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 512 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 62
        // The peer advertised 1 KiB and is delivering half a megabyte: the paste
        // ceiling and the free-space pre-flight were both computed from that
        // figure, so nothing else is holding it to anything.
        prime(harness, id: id, named: "Logs", advertised: 1024)
        begin(harness, id: id, named: "Logs")
        feed(harness, id: id, bytes: bytes)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "size.overrun")
        #expect(harness.collector.representation(id) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — same ordering
        // as the disk-full case.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a folder within its advertised size plus the container's overhead still arrives")
    func extractAllowsContainerOverhead() async throws {
        let fm = FileManager.default
        let harness = try harness(minimumExtractAllowance: 4096)
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 256 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 63
        // Advertised honestly: the archive still carries per-entry headers on top
        // of the file bytes the estimate sums, so the allowance has to have room
        // for them or every honest folder would be refused.
        prime(harness, id: id, named: "Logs", advertised: 256 * 1024)
        begin(harness, id: id, named: "Logs")
        feed(harness, id: id, bytes: bytes)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let tree = try #require(harness.collector.representation(id)?.fileURL)
        #expect(
            try Data(contentsOf: tree.appendingPathComponent("big.log")).count == 256 * 1024)
    }

    @Test("progress is reported in the tree's unit, not the wire's")
    func progressIsReportedInTheOfferUnit() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        // A four-symbol alphabet compresses several-fold, so the wire carries
        // many chunks and both readouts have something to climb through.
        let (scratch, source) = try makeCompressibleTree(
            uncompressedBytes: 4 * 1024 * 1024, symbols: 4)
        defer { try? fm.removeItem(at: scratch) }

        let id: UInt64 = 64
        let sent = Box(0)
        let received = Box(0)
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, extractsDirectoryNamed: "Logs", advertisedByteCount: 4 * 1024 * 1024,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) },
            onProgress: { bytes, _ in received.value = max(received.value, bytes) })
        harness.sender.startDirectoryTransfer(
            transferID: id, generation: 1, sourceDirectoryURL: source, folderName: "Logs",
            uti: ClipboardDirectoryArchive.directoryUTI, maxAcceptByteCount: .max,
            isCurrent: { _ in true },
            onProgress: { bytes, _ in sent.value = max(sent.value, bytes) })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        // The readout's denominator is the offer's uncompressed estimate, so a
        // numerator counting compressed wire bytes crawls to a fraction and then
        // snaps — which reads as a hung paste. Both ends must exceed what
        // actually crossed the wire.
        let wireBytes = try #require(harness.collector.representation(id)?.byteCount)
        #expect(wireBytes < 4 * 1024 * 1024)
        #expect(sent.value > wireBytes)
        #expect(received.value > wireBytes)
    }

    @Test("a fresh pull reusing an abandoned transfer id is served, not refused")
    func retryAfterACancelledPullIsServed() async throws {
        // Transfer ids are derivable from (generation, repIndex, direction), so a
        // second paste of the same representation reuses the id of a pull that
        // timed out. The record of that cancellation must not outlive the
        // registration that replaces it.
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 4096)
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 67
        prime(harness, id: id, named: "Logs", advertised: 4096)
        harness.receiver.cancelAwait(id)

        prime(harness, id: id, named: "Logs", advertised: 4096)
        begin(harness, id: id, named: "Logs")
        feed(harness, id: id, bytes: bytes)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(SHA256.hash(data: bytes))
            })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let tree = try #require(harness.collector.representation(id)?.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("big.log")).count == 4096)
    }

    @Test("an extract that fails on a full volume reports disk space, not a corrupt archive")
    func extractFailureOnAFullVolumeReportsDiskFull() async throws {
        // Once the margin is outrun the extract's own writes are what fail, and
        // AppleArchive reports that as an archive error. Calling it a corrupt
        // folder sends the user off to retry instead of to free space.
        let harness = try harness(freeSpace: { 1024 })
        defer { harness.tearDown() }
        let id: UInt64 = 66
        prime(harness, id: id, named: "Logs", advertised: 4096)
        begin(harness, id: id, named: "Logs")
        let garbage = Data("not an archive".utf8)
        feed(harness, id: id, bytes: garbage)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(garbage.count)
                $0.sha256 = Data(SHA256.hash(data: garbage))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "disk.full")
    }

    @Test("a Begin for a pull this side cancelled is refused, not restaged as a file")
    func cancelledPullRefusesItsReply() async throws {
        let harness = try harness()
        defer { harness.tearDown() }
        let id: UInt64 = 65
        prime(harness, id: id, named: "Logs", advertised: 4096)
        // The lazy pull gives up (a backstop timeout, a cancelled generation)
        // while the peer's reply is already in flight.
        harness.receiver.cancelAwait(id)
        begin(harness, id: id, named: "Logs")

        // No transfer exists, so nothing was staged and no chunk can be blamed on
        // the peer for overrunning a total this side invented.
        #expect(harness.receiver.lastChunkAtForTesting(id) == nil)
        harness.receiver.handleChunk(
            .with {
                $0.transferID = id; $0.offset = 0; $0.data = Data([1, 2, 3])
            })
        // RATIONALE: negative assertion (docs/TESTING.md) — proving nothing was
        // created needs a fixed observation window, not a wait for a signal.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.collector.abortCount == 0)
        #expect(harness.collector.completedCount == 0)
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }
}
