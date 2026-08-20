import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// A folder crossing the real sender and receiver over one data connection, with
/// no archive file at either end.
@Suite("ClipboardDirectoryTransfer", .admissionGated)
struct ClipboardDirectoryTransferTests {
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

    /// A tree holding one incompressible file, so its archive is as big as the
    /// tree and the wire has something to carry.
    private func makeBulkyTree(named name: String, byteCount: Int) throws -> (
        scratch: URL, source: URL
    ) {
        let scratch = makeScratch()
        let source = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try randomBytes(count: byteCount).write(to: source.appendingPathComponent("big.bin"))
        return (scratch, source)
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

    /// What a pull for a folder registers: the name to unpack under, and the
    /// size the offer advertised.
    private func folderPlan(named name: String, advertised: Int)
        -> ClipboardTransferReceiver.Plan
    {
        ClipboardTransferReceiver.Plan(
            uti: ClipboardArchive.directoryUTI, filename: name, extractsDirectoryNamed: name,
            advertisedByteCount: advertised)
    }

    /// Suspends until the transfer has either delivered a representation or
    /// reported an abort.
    private func settle(_ harness: TransferHarness, _ transferID: UInt64) async throws {
        try await harness.collector.gate.wait {
            harness.collector.representation(transferID) != nil || harness.collector.abortCount > 0
        }
    }

    /// The single abort a transfer reported.
    private func abort(_ harness: TransferHarness) throws -> ClipboardStreamAbortInfo {
        try #require(harness.collector.abortInfos.first)
    }

    // MARK: - Round trips

    @Test("a folder streams end to end and is delivered as an extracted tree")
    func folderRoundTrips() async throws {
        let fm = FileManager.default
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x41
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Project", advertised: estimate),
            representation: folderRepresentation(source, named: "Project"))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        #expect(representation.isDirectory)
        #expect(representation.filename == "Project")
        // The tree the rep names, not the archive that carried it
        // (ClipboardDirectoryAccounting pins the two apart).
        #expect(representation.byteCount > 0)

        let tree = try #require(representation.fileURL)
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
        #expect(try probe.stagedFiles().allSatisfy { $0.pathExtension != "aar" })
    }

    @Test("an empty folder still streams and delivers an empty tree")
    func emptyFolderRoundTrips() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let scratch = makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let transferID: UInt64 = 0x42
        harness.pull(
            transferID: transferID, generation: 1, plan: folderPlan(named: "Empty", advertised: 0),
            representation: folderRepresentation(source, named: "Empty"))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        // Archive-container bytes, so even an empty folder is never sized zero.
        #expect(representation.byteCount > 0)
        #expect(try fm.contentsOfDirectory(atPath: #require(representation.fileURL).path).isEmpty)
    }

    // MARK: - Failure and cleanup

    @Test("a digest mismatch in the trailer deletes the extracted tree")
    func digestMismatchDeletesTree() async throws {
        let fm = FileManager.default
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try clipboardArchiveBytes(ofDirectoryAt: source)

        let transferID: UInt64 = 0x43
        harness.expect(
            transferID: transferID,
            plan: folderPlan(named: "Project", advertised: bytes.count))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, bytes)
            // A whole, well-formed archive under a digest that does not describe
            // it, so the tree is already on disk when the only detector of a
            // corrupted payload fires.
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: Data(repeating: 0xAA, count: 32))),
                fd: far)
        }
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .digestMismatch)
        #expect(harness.collector.representation(transferID) == nil)
        // The tree is removed on the receive lane before the abort is delivered,
        // so nothing is staged by the time the pull hears about it.
        #expect(try probe.stagedFiles().isEmpty)
    }

    @Test("a truncated archive aborts with extract.error and leaves no tree")
    func truncationAborts() async throws {
        let fm = FileManager.default
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }
        let half = Data(try clipboardArchiveBytes(ofDirectoryAt: source).dropLast(64))

        let transferID: UInt64 = 0x44
        harness.expect(
            transferID: transferID, plan: folderPlan(named: "Project", advertised: half.count))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, half)
            // Size and digest both agree with what arrived: only the extract
            // itself can tell that the archive is incomplete.
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: sha256(half))), fd: far)
        }
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .extractError)
        #expect(harness.collector.representation(transferID) == nil)
        #expect(try probe.stagedFiles().isEmpty)
    }

    @Test("cancelling the generation mid-extract deletes the partial tree")
    func cancelDeletesPartialTree() async throws {
        let fm = FileManager.default
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeBulkyTree(named: "Project", byteCount: 8 * 1024 * 1024)
        defer { try? fm.removeItem(at: scratch) }

        // The generation the cancel names is read back out of the id, so the two
        // have to agree.
        let transferID = ClipboardTransferID.make(generation: 1, repIndex: 0, hostMinted: true)
        // Cancel from inside the stream, on the first report the *extract* made,
        // so a whole pacing quantum of tree is on disk when the pull gives up —
        // rather than wherever the runner happened to schedule the test next.
        let cancelled = Box(false)
        harness.onReceiveProgress.value = { [weak harness] extracted, _ in
            guard extracted > 0, !cancelled.value else { return }
            cancelled.value = true
            harness?.inbox.cancel(generation: 1)
        }
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Project", advertised: 8 * 1024 * 1024),
            representation: folderRepresentation(source, named: "Project"))
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .cancelled)
        #expect(harness.collector.representation(transferID) == nil)
        // RATIONALE: filesystem-appearance poll (docs/TESTING.md) — a cancelled
        // pull is resolved by the inbox the moment it is asked, so the partial
        // tree is still being torn down on the receive lane when the abort lands.
        try await waitUntil { ((try? probe.stagedFiles()) ?? []).isEmpty }
    }

    @Test("a peer that aborts mid-extract deletes the partial tree")
    func peerAbortDeletesPartialTree() async throws {
        let fm = FileManager.default
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeBulkyTree(named: "Project", byteCount: 256 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        let bytes = try clipboardArchiveBytes(ofDirectoryAt: source)
        let half = Data(bytes.prefix(bytes.count / 2))

        let transferID: UInt64 = 0x45
        harness.expect(
            transferID: transferID, plan: folderPlan(named: "Project", advertised: 256 * 1024))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, half)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .aborted(rawCode: ClipboardStreamAbortCode.readError.rawValue)),
                fd: far)
        }
        try await settle(harness, transferID)

        // The sender's own reason, not the truncation it caused.
        #expect(try abort(harness).code == .readError)
        #expect(harness.collector.representation(transferID) == nil)
        #expect(try probe.stagedFiles().isEmpty)
    }

    @Test("a send parked on a peer that stopped reading is released by the connection's own bound")
    func parkedSendIsReleasedByTheConnectionsBound() async throws {
        // Flow control is the kernel's, so a peer that takes the reply and then
        // neither reads nor closes leaves the encode parked inside `write(2)`;
        // the connection's own bound is what ends it.
        let fm = FileManager.default
        let harness = TransferHarness(socketTimeout: 0.3)
        defer { harness.tearDown() }
        let (scratch, source) = try makeBulkyTree(named: "Project", byteCount: 4 * 1024 * 1024)
        defer { try? fm.removeItem(at: scratch) }

        // Signalled before the harness is torn down, so the peer's thread always
        // unwinds.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let collector = harness.collector
        let transferID: UInt64 = 0x46
        harness.outbox.serve(
            transferID: transferID, generation: 1,
            representation: folderRepresentation(source, named: "Project"),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: false,
            isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    _ = readTransferReply(fd: far)
                    release.wait()
                    ClipboardDataConnection.end(fd: far)
                }
            },
            onComplete: { collector.sendFinished(transferID, success: $0) })

        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)
        #expect(collector.outboundMetrics.isEmpty)
    }

    @Test("a transfer that failed frees its id, so the same outbox serves a second send for it")
    func failedTransferFreesItsIdOnTheSameOutbox() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        // The peer takes the reply and vanishes, so the send fails under it.
        let collector = harness.collector
        let transferID: UInt64 = 0x47
        harness.outbox.serve(
            transferID: transferID, generation: 1,
            representation: folderRepresentation(source, named: "Project"),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: false,
            isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    _ = readTransferReply(fd: far)
                    ClipboardDataConnection.end(fd: far)
                }
            },
            onComplete: { collector.sendFinished(transferID, success: $0) })
        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)

        // Same outbox, same id: transfer ids are derivable, so the peer's retry
        // reuses this one. The table entry has to be gone, or the second call is
        // dropped as a duplicate and the peer waits for a reply that never comes.
        let received = Box<ReceivedTransfer?>(nil)
        let served = AsyncGate()
        harness.outbox.serve(
            transferID: transferID, generation: 1,
            representation: folderRepresentation(source, named: "Project"),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: false,
            isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    received.value = try? receiveTransfer(fd: far)
                    served.notify()
                }
            })

        try await served.wait { received.value != nil }
        let transfer = try #require(received.value)
        #expect(transfer.isComplete)
        let tree = try extractedClipboardArchive(transfer.payload, named: "Project")
        defer { try? fm.removeItem(at: tree.deletingLastPathComponent()) }
        #expect(
            try String(contentsOf: tree.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
    }

    @Test("a volume below the free-space margin refuses a folder before a byte is staged")
    func refusedWhenVolumeIsFull() async throws {
        let probe = StagingProbe(freeSpace: { _ in 1024 })
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }

        let transferID: UInt64 = 0x48
        harness.expect(
            transferID: transferID, plan: folderPlan(named: "Project", advertised: 4096))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            // Holds the connection open and writes no payload: the read below
            // returns once the receiver has refused and closed its end, so
            // nothing here sleeps.
            var parked = [UInt8](repeating: 0, count: 1)
            _ = parked.withUnsafeMutableBytes { raw in
                try? ClipboardDataConnection.read(fd: far, into: raw)
            }
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .diskFull)
        // A streamed folder declares no size on the wire, so the estimate its
        // offer advertised is the honest figure to report as "needed".
        #expect(info.neededBytes == 4096)
        #expect(info.availableBytes == 1024)
        #expect(try probe.stagedFiles().isEmpty)
    }

    @Test("the sender aborts a folder that outgrows the requester's ceiling")
    func abortsPastAcceptCeiling() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeSourceTree()
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x49
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Project", advertised: 4096),
            // A stale estimate of zero passes the up-front refusal, so the
            // ceiling can only be enforced as bytes are produced — which is the
            // point: an archive's size is not knowable when the transfer starts.
            representation: folderRepresentation(source, named: "Project", estimate: 0),
            maxAcceptByteCount: 64)
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .diskFull)
        #expect(harness.collector.representation(transferID) == nil)
    }
}
