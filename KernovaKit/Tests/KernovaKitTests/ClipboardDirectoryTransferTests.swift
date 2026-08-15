import CryptoKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// A folder crossing the real sender and receiver over a socketpair, with no
/// archive file at either end.
@Suite("ClipboardDirectoryTransfer")
struct ClipboardDirectoryTransferTests {
    private static let chunk = 4096
    private static let window = 16384  // 4 chunks

    private func harness(
        windowBytes: Int = window, freeSpace: @escaping @Sendable () -> Int64 = { 100 << 30 },
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        archiveSource: ClipboardArchiveSourceFactory? = nil
    ) throws -> StreamHarness {
        try StreamHarness(
            chunkSize: Self.chunk, windowBytes: windowBytes,
            minimumExtractAllowance: minimumExtractAllowance,
            freeSpaceProvider: { _ in freeSpace() },
            archiveSource: archiveSource)
    }

    private func makeScratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "dirtransfer-\(UUID().uuidString)", isDirectory: true)
    }

    /// A small source tree with nesting, a symlink, and an empty folder.
    private func makeSourceTree() throws -> (scratch: URL, source: URL) {
        let fm = FileManager.default
        let scratch = makeScratch()
        let source = scratch.appendingPathComponent("Project", isDirectory: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            at: source.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        try "readme".write(
            to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "nested".write(
            to: source.appendingPathComponent("sub/n.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path, withDestinationPath: "README.md")
        return (scratch, source)
    }

    /// Every archive byte a real transfer of `source` puts on the wire.
    private func archiveBytes(of source: URL) throws -> Data {
        try clipboardArchiveBytes(ofDirectoryAt: source)
    }

    /// A folder representation the sender streams as its tree, carrying the
    /// stat-walk estimate the offer would have advertised.
    private func folderRepresentation(_ source: URL, named name: String, estimate: Int? = nil)
        -> ClipboardContent.Representation
    {
        ClipboardContent.Representation(
            directorySourceURL: source,
            estimatedByteCount: estimate ?? ClipboardArchive.estimatedByteCount(at: source),
            filename: name)
    }

    /// The priming a requester performs before it sends its `ClipboardRequest`,
    /// funnelling delivery into the harness collector.
    private func prime(
        _ harness: StreamHarness, id: UInt64, named name: String, advertised: Int = 0
    ) {
        let collector = harness.collector
        harness.receiver.awaitTransfer(
            id, extractsDirectoryNamed: name, advertisedByteCount: advertised,
            onComplete: { collector.complete(id, $0) },
            onAbort: { collector.abort($0) })
    }

    /// Announces a folder transfer with no declared total, exactly as the sender
    /// does for any archived payload.
    private func begin(_ harness: StreamHarness, id: UInt64, named name: String) {
        harness.receiver.handleBegin(
            .with {
                $0.generation = 1
                $0.transferID = id
                $0.uti = ClipboardArchive.directoryUTI
                $0.totalBytes = 0
                $0.filename = name
                $0.isInline = false
                $0.isArchive = true
            })
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

    // MARK: - Round trips

    @Test("a folder streams end to end and is delivered as an extracted tree")
    func folderRoundTrips() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let id: UInt64 = 41
        prime(harness, id: id, named: "Project")
        harness.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(source, named: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let rep = try #require(harness.collector.representation(id))
        #expect(rep.isDirectory)
        #expect(rep.filename == "Project")
        // The tree the rep names, not the archive that carried it
        // (ClipboardDirectoryAccounting pins the two apart).
        #expect(rep.byteCount > 0)

        let tree = try #require(rep.fileURL)
        #expect(tree.lastPathComponent == "Project")
        #expect(
            try String(contentsOf: tree.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
        #expect(
            try String(contentsOf: tree.appendingPathComponent("sub/n.txt"), encoding: .utf8)
                == "nested")
        var isDir: ObjCBool = false
        #expect(
            fm.fileExists(atPath: tree.appendingPathComponent("empty").path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(
            try fm.destinationOfSymbolicLink(atPath: tree.appendingPathComponent("link").path)
                == "README.md")
        // The point of the exercise: no archive lands anywhere.
        #expect(
            materializedFiles(under: harness.stagingTempRoot).allSatisfy {
                $0.pathExtension != "aar"
            })
    }

    @Test("an empty folder still streams and delivers an empty tree")
    func emptyFolderRoundTrips() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let scratch = makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let id: UInt64 = 42
        prime(harness, id: id, named: "Empty")
        harness.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(source, named: "Empty"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.representation(id) != nil }
        let rep = try #require(harness.collector.representation(id))
        // Archive-container bytes, so even an empty folder is never sized zero.
        #expect(rep.byteCount > 0)
        #expect(try fm.contentsOfDirectory(atPath: #require(rep.fileURL).path).isEmpty)
    }

    @Test("a folder completes under a one-chunk credit window")
    func folderCompletesUnderTinyWindow() async throws {
        let fm = FileManager.default
        let harness = try harness(windowBytes: Self.chunk)
        defer { harness.tearDown() }
        let scratch = makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Big", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // Random, so LZ4 cannot shrink it and the archive runs to many
        // windows: the encode side then parks on credit repeatedly.
        var generator = SystemRandomNumberGenerator()
        var payload = Data(count: 512 * 1024)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<raw.count { base[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        try payload.write(to: source.appendingPathComponent("random.bin"))

        let id: UInt64 = 43
        prime(harness, id: id, named: "Big")
        harness.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(source, named: "Big"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait {
            harness.collector.representation(id) != nil || harness.collector.abortCount > 0
        }
        #expect(harness.collector.abortInfos.map(\.code) == [])
        let tree = try #require(harness.collector.representation(id)?.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("random.bin")) == payload)
    }

    // MARK: - Failure and cleanup

    @Test("an unprimed folder transfer is refused at Begin, before anything is staged")
    func unprimedUndeclaredTotalAborts() async throws {
        // Directory-ness and the size to hold the extract to both ride the pull
        // that asked for the folder, so an archive nobody primed has no name to
        // unpack under and no bound to enforce.
        let harness = try harness()
        defer { harness.tearDown() }
        let id: UInt64 = 44
        begin(harness, id: id, named: "Project")
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "payload.unexpected")
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("a digest mismatch at End deletes the extracted tree")
    func digestMismatchDeletesTree() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 45
        prime(harness, id: id, named: "Project")
        begin(harness, id: id, named: "Project")
        feed(harness, id: id, bytes: bytes)
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(bytes.count)
                $0.sha256 = Data(repeating: 0xAA, count: 32)
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "digest.mismatch")
        #expect(harness.collector.representation(id) == nil)
        // The tree was already on disk when the digest — the only detector of a
        // corrupted archive — failed, so it has to be removed.
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the tree is
        // deleted on the write lane after the abort is delivered, so no collector
        // signal covers it.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a truncated archive aborts with extract.error and leaves no tree")
    func truncationAborts() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let half = Data(try archiveBytes(of: source).prefix(while: { _ in true }).dropLast(64))

        let id: UInt64 = 46
        prime(harness, id: id, named: "Project")
        begin(harness, id: id, named: "Project")
        feed(harness, id: id, bytes: half)
        // Size and digest both agree with what arrived: only the extract itself
        // can tell that the archive is incomplete.
        harness.receiver.handleEnd(
            .with {
                $0.transferID = id
                $0.totalBytes = UInt64(half.count)
                $0.sha256 = Data(SHA256.hash(data: half))
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "extract.error")
        #expect(harness.collector.representation(id) == nil)
        #expect(materializedFiles(under: harness.stagingTempRoot).isEmpty)
    }

    @Test("cancelling the generation mid-extract deletes the partial tree")
    func cancelDeletesPartialTree() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 47
        prime(harness, id: id, named: "Project")
        begin(harness, id: id, named: "Project")
        feed(harness, id: id, bytes: Data(bytes.prefix(bytes.count / 2)))
        harness.receiver.cancel(generation: 1)

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "cancelled")
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — the teardown
        // runs on the write lane after the abort is delivered.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("a peer abort mid-extract deletes the partial tree")
    func peerAbortDeletesPartialTree() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try archiveBytes(of: source)

        let id: UInt64 = 48
        prime(harness, id: id, named: "Project")
        begin(harness, id: id, named: "Project")
        feed(harness, id: id, bytes: Data(bytes.prefix(bytes.count / 2)))
        harness.receiver.handleAbort(
            .with {
                $0.transferID = id; $0.code = "read.error"; $0.message = "gone"
            })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — same ordering
        // as the cancellation case above.
        try await waitUntil { materializedFiles(under: harness.stagingTempRoot).isEmpty }
    }

    @Test("an abort reaches a transfer parked reading its source, and frees its id")
    func abortUnwindsAParkedSourceRead() async throws {
        // Nothing signals the transfer's own condition into a park that happens
        // *inside* the source, so before this the receiver's stall abort,
        // supersession and channel teardown all woke the wrong object — the
        // transfer stayed registered, and the peer's retry (transfer ids are
        // derivable, so it reuses this one) was dropped as a duplicate.
        let source = ParkingChunkReader()
        let first = try harness(archiveSource: { _, _, _ in source })
        defer { first.tearDown() }
        let fm = FileManager.default
        let (scratch, tree) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let id: UInt64 = 51
        let firstOutcome = Box<Bool?>(nil)
        let firstGate = AsyncGate()
        prime(first, id: id, named: "Project")
        first.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(tree, named: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true },
            onComplete: { success in
                firstOutcome.value = success
                firstGate.notify()
            })
        try await source.parked.wait { source.parkedReads > 0 }

        first.sender.cancel(generation: 1)
        // Unwinds promptly rather than sitting until the source happens to
        // produce something, which for a stalled encoder is never.
        try await firstGate.wait { firstOutcome.value != nil }
        #expect(firstOutcome.value == false)

        // The id is free again, so the peer's retry is served rather than
        // swallowed by the duplicate-transfer guard.
        let retry = ParkingChunkReader()
        let retryHarness = try self.harness(archiveSource: { _, _, _ in retry })
        defer { retryHarness.tearDown() }
        prime(retryHarness, id: id, named: "Project")
        retryHarness.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(tree, named: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })
        try await retry.parked.wait { retry.parkedReads > 0 }
        retry.close()
    }

    @Test("a second transfer for a freed id is accepted by the same sender")
    func abortedTransferFreesItsIdOnTheSameSender() async throws {
        let source = ParkingChunkReader()
        let second = ParkingChunkReader()
        let sources = Box<[ParkingChunkReader]>([second, source])
        let rig = try harness(archiveSource: { _, _, _ in
            var remaining = sources.value
            let next = remaining.removeLast()
            sources.value = remaining
            return next
        })
        defer { rig.tearDown() }
        let fm = FileManager.default
        let (scratch, tree) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let id: UInt64 = 52
        let done = AsyncGate()
        let outcome = Box<Bool?>(nil)
        prime(rig, id: id, named: "Project")
        rig.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(tree, named: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true },
            onComplete: { success in
                outcome.value = success
                done.notify()
            })
        try await source.parked.wait { source.parkedReads > 0 }
        rig.sender.handleAbort(transferID: id)
        try await done.wait { outcome.value != nil }

        // Same sender, same id: the table entry has to be gone, or this call is
        // silently dropped and the peer waits for a Begin that never comes.
        prime(rig, id: id, named: "Project")
        rig.sender.startTransfer(
            transferID: id, generation: 1,
            representation: folderRepresentation(tree, named: "Project"),
            maxAcceptByteCount: .max, isInline: false, isCurrent: { _ in true })
        try await second.parked.wait { second.parkedReads > 0 }
        second.close()
    }

    @Test("a volume below the free-space margin refuses a folder at Begin")
    func refusedWhenVolumeIsFull() async throws {
        let harness = try harness(freeSpace: { 1024 })
        defer { harness.tearDown() }
        let id: UInt64 = 49
        prime(harness, id: id, named: "Project", advertised: 4096)
        begin(harness, id: id, named: "Project")

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        let info = try #require(harness.collector.abortInfos.first)
        #expect(info.code == "disk.full")
        // A streamed folder declares no size on the wire, so the estimate its
        // offer advertised is the honest figure to report as "needed".
        #expect(info.neededBytes == 4096)
    }

    @Test("the sender aborts a folder that outgrows the requester's ceiling")
    func abortsPastAcceptCeiling() async throws {
        let fm = FileManager.default
        let harness = try harness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let id: UInt64 = 50
        prime(harness, id: id, named: "Project")
        // The ceiling can only be enforced as bytes are produced: the archive's
        // size is not knowable when the transfer starts.
        harness.sender.startTransfer(
            transferID: id, generation: 1,
            // A stale estimate of zero passes the up-front check, so the ceiling
            // can only be enforced as bytes are produced — which is the point.
            representation: folderRepresentation(source, named: "Project", estimate: 0),
            maxAcceptByteCount: 64, isInline: false, isCurrent: { _ in true })

        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        #expect(harness.collector.abortInfos.first?.code == "disk.full")
        #expect(harness.collector.representation(id) == nil)
    }
}
