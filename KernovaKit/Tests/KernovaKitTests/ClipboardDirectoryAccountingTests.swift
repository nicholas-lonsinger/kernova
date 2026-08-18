import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What a folder transfer is measured in.
///
/// Its wire bytes are compressed and its tree is not, and compression reaches ~100:1
/// on repetitive data — so every guard and every readout that reasons about "how big is
/// this" has to be expressed in the tree's unit, not the wire's. These are the
/// tests that fail when one of them slips back to counting wire bytes.
@Suite("ClipboardDirectoryAccounting")
struct ClipboardDirectoryAccountingTests {
    private func makeScratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "diraccounting-\(UUID().uuidString)", isDirectory: true)
    }

    /// A tree whose archive is a fraction of the tree it unpacks to: one file of
    /// a single repeated byte, which LZ4 shrinks to a couple of KiB whatever its
    /// size.
    private func makeCompressibleTree(
        uncompressedBytes: Int
    ) throws -> (scratch: URL, source: URL) {
        let fm = FileManager.default
        let scratch = makeScratch()
        let source = scratch.appendingPathComponent("Logs", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: uncompressedBytes)
            .write(to: source.appendingPathComponent("big.log"))
        return (scratch, source)
    }

    /// A folder representation the sender streams as its tree, carrying the
    /// stat-walk estimate the offer would have advertised.
    private func folderRepresentation(_ source: URL, named name: String, estimate: Int)
        -> ClipboardContent.Representation
    {
        ClipboardContent.Representation(
            directorySourceURL: source, estimatedByteCount: estimate, filename: name)
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

    @Test("a volume that fills is caught while the tree is being written, not per wire byte")
    func diskGuardIsPacedByTheTreeNotTheWire() async throws {
        let fm = FileManager.default
        // Roomy at the pre-flight and below the margin from the first extracted
        // byte, so the only check that can refuse is the one the extract runs.
        let probe = StagingProbe(freeSpace: { $0 == 0 ? 100 << 30 : 1024 })
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 4 * 1024 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        // The point: this whole archive fits inside a single read off the socket,
        // so a guard clocked on arriving wire bytes has nothing to fire on, while
        // the tree it writes runs to megabytes.
        #expect(
            try clipboardArchiveBytes(ofDirectoryAt: source).count
                < ClipboardStreamTuning.dataReadBufferBytes)

        let transferID: UInt64 = 0x61
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: 4 * 1024 * 1024),
            representation: folderRepresentation(source, named: "Logs", estimate: 4 * 1024 * 1024))
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .diskFull)
        #expect(harness.collector.representation(transferID) == nil)
        // The refusal is raised inside the extract, which removes its own output
        // before the abort is delivered.
        #expect(try probe.stagedFiles().isEmpty)
    }

    @Test("the receiver paces its extract guard on its own quantum, not on the read buffer")
    func extractGuardTakesThePacingTheReceiverWasGiven() async throws {
        let fm = FileManager.default
        let probe = StagingProbe(freeSpace: { $0 == 0 ? 100 << 30 : 1024 })
        // A tree smaller than every other quantum in the pipeline: the transport
        // reads 64 KiB at a time and the production pacing is a megabyte, so a
        // guard taking either would first check past the last byte and the
        // transfer would complete. It fires — repeatedly — only on the quantum
        // the receiver was handed.
        let tree = 32 * 1024
        #expect(tree < ClipboardStreamTuning.dataReadBufferBytes)
        #expect(tree < ClipboardStreamTuning.extractPacingBytes)
        let harness = TransferHarness(
            freeSpaceProvider: probe.provider, extractPacingBytes: tree / 8)
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: tree)
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x62
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: tree),
            representation: folderRepresentation(source, named: "Logs", estimate: tree))
        try await settle(harness, transferID)

        #expect(harness.collector.representation(transferID) == nil)
        #expect(try abort(harness).code == .diskFull)
    }

    @Test("a folder within its advertised size plus the container's overhead still arrives")
    func extractAllowsContainerOverhead() async throws {
        let fm = FileManager.default
        // A small floor so it doesn't swallow the test; the production value
        // exists for byte-free trees, not for this shape.
        let harness = TransferHarness(minimumExtractAllowance: 4096)
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 256 * 1024)
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x63
        // Advertised honestly: the archive still carries per-entry headers on top
        // of the file bytes the estimate sums, so the allowance has to have room
        // for them or every honest folder would be refused.
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: 256 * 1024),
            representation: folderRepresentation(source, named: "Logs", estimate: 256 * 1024))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        // The overhead made visible: what was extracted is the tree *and* its
        // headers, which is more than the figure the ceiling was computed from.
        #expect(representation.byteCount > 256 * 1024)
        let tree = try #require(representation.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("big.log")).count == 256 * 1024)
    }

    @Test("the delivered folder is sized by its tree, not by the archive that carried it")
    func deliveredFolderCarriesTheTreesSize() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 512 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        // Driven by hand so the test owns the exact bytes the digest covers.
        let bytes = try clipboardArchiveBytes(ofDirectoryAt: source)

        let transferID: UInt64 = 0x64
        harness.expect(
            transferID: transferID, plan: folderPlan(named: "Logs", advertised: 512 * 1024))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, bytes)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: sha256(bytes))), fd: far)
        }
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        // The rep's bytes are the tree at its URL, and the offer advertised that
        // figure too — the compressed count is a different unit and, here, ~100×
        // smaller.
        #expect(representation.byteCount >= 512 * 1024)
        #expect(representation.byteCount > bytes.count)
        // The digest still covers the wire bytes: it is the transfer's integrity
        // gate, and re-hashing the tree would prove nothing about what arrived.
        guard case .file(_, _, let digest) = representation.source else {
            Issue.record("Expected a file-backed representation, got \(representation.source)")
            return
        }
        #expect(digest == sha256(bytes))
    }

    @Test("the requester's ceiling stops a folder by the tree it unpacks to, not by the wire")
    func senderCeilingIsMeasuredInTheTreesUnit() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 512 * 1024)
        defer { try? fm.removeItem(at: scratch) }
        // A ceiling the wire never comes close to: the whole archive is a couple
        // of KiB, so a guard counting wire bytes lets the half-megabyte tree
        // through to a requester that said it had room for 64 KiB.
        let ceiling = 64 * 1024
        #expect(try clipboardArchiveBytes(ofDirectoryAt: source).count < ceiling)

        let transferID: UInt64 = 0x65
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: 512 * 1024),
            // A stale estimate of zero passes the up-front refusal, so the
            // ceiling can only be enforced against what the archive produces.
            representation: folderRepresentation(source, named: "Logs", estimate: 0),
            maxAcceptByteCount: UInt64(ceiling))
        try await settle(harness, transferID)

        #expect(try abort(harness).code == .diskFull)
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("a folder whose tree fits the requester's ceiling still arrives")
    func senderCeilingPassesATreeThatFits() async throws {
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 512 * 1024)
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x66
        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: 512 * 1024),
            representation: folderRepresentation(source, named: "Logs", estimate: 512 * 1024),
            maxAcceptByteCount: 4 * 1024 * 1024)
        try await settle(harness, transferID)

        let tree = try #require(harness.collector.representation(transferID)?.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("big.log")).count == 512 * 1024)
    }

    @Test("a fresh pull reusing an abandoned transfer id is served, not refused")
    func retryAfterACancelledPullIsServed() async throws {
        // Transfer ids are derivable from (generation, repIndex, direction), so a
        // second paste of the same representation reuses the id of a pull that
        // timed out. The record of that cancellation must not outlive the
        // registration that replaces it.
        let fm = FileManager.default
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (scratch, source) = try makeCompressibleTree(uncompressedBytes: 4096)
        defer { try? fm.removeItem(at: scratch) }

        let transferID: UInt64 = 0x67
        harness.expect(transferID: transferID, plan: folderPlan(named: "Logs", advertised: 4096))
        harness.inbox.cancelAwait(transferID)

        harness.pull(
            transferID: transferID, generation: 1,
            plan: folderPlan(named: "Logs", advertised: 4096),
            representation: folderRepresentation(source, named: "Logs", estimate: 4096))
        try await settle(harness, transferID)

        let tree = try #require(harness.collector.representation(transferID)?.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("big.log")).count == 4096)
    }

    @Test("an extract that fails on a full volume reports disk space, not a corrupt archive")
    func extractFailureOnAFullVolumeReportsDiskFull() async throws {
        // Once the margin is outrun the extract's own writes are what fail, and
        // AppleArchive reports that as an archive error. Calling it a corrupt
        // folder sends the user off to retry instead of to free space.
        let probe = StagingProbe(freeSpace: { $0 == 0 ? 100 << 30 : 1024 })
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }

        let transferID: UInt64 = 0x68
        harness.expect(transferID: transferID, plan: folderPlan(named: "Logs", advertised: 4096))
        harness.openPull(transferID: transferID, generation: 1) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            let garbage = Data("not an archive".utf8)
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, garbage)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: sha256(garbage))), fd: far)
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .diskFull)
    }

    @Test("a reply for a pull this side cancelled is refused, not staged")
    func cancelledPullRefusesItsReply() async throws {
        let probe = StagingProbe()
        let harness = TransferHarness(freeSpaceProvider: probe.provider)
        defer { harness.tearDown() }

        let transferID: UInt64 = 0x69
        harness.expect(transferID: transferID, plan: folderPlan(named: "Logs", advertised: 4096))
        // The lazy pull gives up (a backstop timeout, a cancelled generation)
        // while the peer's reply is already in flight.
        harness.inbox.cancelAwait(transferID)

        let (near, far) = try makeRawSocketPair()
        harness.inbox.adopt(
            fd: near,
            reply: Kernova_V1_ClipboardTransferReply.with {
                $0.transferID = transferID
                $0.isArchive = true
                $0.isInline = false
                $0.totalBytes = 0
            })
        // The refusal a peer sees is its connection going away, so its own read
        // ending is the signal — nothing has to be waited out.
        let closedOnThePeer = await offCooperativePool { () -> Bool in
            defer { ClipboardDataConnection.end(fd: far) }
            var byte = [UInt8](repeating: 0, count: 1)
            let got = byte.withUnsafeMutableBytes { raw in
                (try? ClipboardDataConnection.read(fd: far, into: raw)) ?? -1
            }
            return got == 0
        }

        #expect(closedOnThePeer)
        #expect(harness.collector.abortCount == 0)
        #expect(harness.collector.representation(transferID) == nil)
        // No transfer ever started, so nothing asked the volume whether it had
        // room and no destination was reserved to stage a payload into.
        #expect(probe.queryCount == 0)
    }
}
