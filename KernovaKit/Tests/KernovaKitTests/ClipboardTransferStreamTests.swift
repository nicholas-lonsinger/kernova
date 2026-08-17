import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The per-transfer data connection end to end: a real
/// ``ClipboardTransferSender`` and ``ClipboardTransferReceiver`` over a
/// socketpair with both ends running, in both header orders.
@Suite("ClipboardTransferStream")
struct ClipboardTransferStreamTests {
    /// What a stubbed dial throws, shaped like the guest dialler's own error —
    /// a plain enum carrying its reason — so a test can look for that reason in
    /// what the failed transfer reports.
    private enum DialFailure: Error {
        case refused(String)
    }

    /// A unique scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    /// A tree exercising every shape the archive's key set carries: nesting, an
    /// empty directory, unicode names, a symlink, a package, and the exec bit.
    private func makeFixtureTree(in scratch: URL) throws -> URL {
        let fm = FileManager.default
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("a/b/c", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "top".write(
            to: source.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "deep".write(
            to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(
            at: source.appendingPathComponent("emptydir", isDirectory: true),
            withIntermediateDirectories: true)
        let unicode = source.appendingPathComponent("Ünïcødé 🎉", isDirectory: true)
        try fm.createDirectory(at: unicode, withIntermediateDirectories: true)
        try "ok".write(
            to: unicode.appendingPathComponent("naïve — файл.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path, withDestinationPath: "top.txt")
        let rtfd = source.appendingPathComponent("note.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfd, withIntermediateDirectories: true)
        try "{\\rtf1}".write(
            to: rtfd.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
        let exe = source.appendingPathComponent("run.sh")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return source
    }

    // MARK: - Round trips

    @Test("a raw inline payload round-trips resident, with no archive on the wire")
    func rawInlineRoundTrips() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let payload = Data("the quick brown fox".utf8)
        let transferID: UInt64 = 0x11
        harness.push(
            transferID: transferID, generation: 1,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: payload.count),
            representation: .init(uti: "public.utf8-plain-text", data: payload), isInline: true)
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        #expect(representation.inMemoryData == payload)
        #expect(harness.collector.abortCount == 0)
        let inbound = try #require(harness.collector.inboundMetrics.first)
        #expect(inbound.inbound?.streamedToDisk == false)
        #expect(inbound.wireByteCount == payload.count)
    }

    @Test("a file round-trips byte-identically under its offer's name")
    func fileRoundTrips() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let payload = patternedBytes(count: 512 * 1024, multiplier: 7, offset: 3)
        let file = scratch.appendingPathComponent("payload.bin")
        try payload.write(to: file)

        let transferID: UInt64 = 0x21
        harness.pull(
            transferID: transferID, generation: 2,
            plan: .init(
                uti: "public.data", filename: "payload.bin", advertisedByteCount: payload.count),
            representation: .init(
                uti: "public.data", fileURL: file, byteCount: payload.count,
                filename: "payload.bin"))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        let url = try #require(representation.fileURL)
        #expect(url.lastPathComponent == "payload.bin")
        #expect(try Data(contentsOf: url) == payload)
        #expect(representation.byteCount == payload.count)
        // Nothing but the extracted file: no archive is ever materialized.
        #expect(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["payload.bin"])
    }

    @Test("a folder round-trips its whole tree — nesting, unicode, a symlink, a package, the exec bit")
    func folderRoundTrips() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let source = try makeFixtureTree(in: scratch)
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        let transferID: UInt64 = 0x31
        harness.pull(
            transferID: transferID, generation: 3,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "source"))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        let out = try #require(representation.fileURL)
        #expect(out.lastPathComponent == "source")
        #expect(representation.isDirectory)
        #expect(try String(contentsOf: out.appendingPathComponent("top.txt"), encoding: .utf8) == "top")
        #expect(
            try String(contentsOf: out.appendingPathComponent("a/b/c/deep.txt"), encoding: .utf8)
                == "deep")
        #expect(
            try String(
                contentsOf: out.appendingPathComponent("Ünïcødé 🎉/naïve — файл.txt"), encoding: .utf8)
                == "ok")
        #expect(
            try String(
                contentsOf: out.appendingPathComponent("note.rtfd/TXT.rtf"), encoding: .utf8)
                == "{\\rtf1}")
        var isDir: ObjCBool = false
        #expect(
            fm.fileExists(atPath: out.appendingPathComponent("emptydir").path, isDirectory: &isDir)
                && isDir.boolValue)
        let linkPath = out.appendingPathComponent("link.txt").path
        #expect(
            (try fm.attributesOfItem(atPath: linkPath)[.type] as? FileAttributeType)
                == .typeSymbolicLink)
        #expect(try fm.destinationOfSymbolicLink(atPath: linkPath) == "top.txt")
        let mode =
            (try fm.attributesOfItem(atPath: out.appendingPathComponent("run.sh").path)[
                .posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o111 != 0)
    }

    @Test("a zero-byte file round-trips, and so does an empty inline payload")
    func zeroByteRoundTrips() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let empty = scratch.appendingPathComponent("empty.bin")
        try Data().write(to: empty)

        let fileHarness = TransferHarness()
        defer { fileHarness.tearDown() }
        let fileTransfer: UInt64 = 0x41
        fileHarness.pull(
            transferID: fileTransfer, generation: 4,
            plan: .init(uti: "public.data", filename: "empty.bin", advertisedByteCount: 0),
            representation: .init(
                uti: "public.data", fileURL: empty, byteCount: 0, filename: "empty.bin"))
        try await settle(fileHarness, fileTransfer)
        let fileRep = try #require(fileHarness.collector.representation(fileTransfer))
        #expect(fileRep.byteCount == 0)
        #expect(try Data(contentsOf: #require(fileRep.fileURL)).isEmpty)

        let inlineHarness = TransferHarness()
        defer { inlineHarness.tearDown() }
        let inlineTransfer: UInt64 = 0x42
        inlineHarness.push(
            transferID: inlineTransfer, generation: 4,
            plan: .init(uti: "public.utf8-plain-text"),
            representation: .init(uti: "public.utf8-plain-text", data: Data()), isInline: true)
        try await settle(inlineHarness, inlineTransfer)
        #expect(try #require(inlineHarness.collector.representation(inlineTransfer)).byteCount == 0)
    }

    @Test("a payload larger than every buffer in the pipeline round-trips byte-identically")
    func multiBufferPayloadRoundTrips() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        // Past the socket buffer, the read buffer, and the encoder's own block
        // size several hundred times over, so nothing about the transfer fits in
        // one pass at any stage.
        let byteCount = 104 * 1024 * 1024 + 7
        let file = scratch.appendingPathComponent("big.bin")
        try Data(repeating: 0x5A, count: byteCount).write(to: file)

        let transferID: UInt64 = 0x51
        harness.pull(
            transferID: transferID, generation: 5,
            plan: .init(uti: "public.data", filename: "big.bin", advertisedByteCount: byteCount),
            representation: .init(
                uti: "public.data", fileURL: file, byteCount: byteCount, filename: "big.bin"))
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        let out = try #require(representation.fileURL)
        #expect(representation.byteCount == byteCount)
        let source = try Data(contentsOf: file, options: .mappedIfSafe)
        let landed = try Data(contentsOf: out, options: .mappedIfSafe)
        #expect(landed == source)
        // The wire carried the compressed archive, not the payload.
        let inbound = try #require(harness.collector.inboundMetrics.first)
        #expect(inbound.wireByteCount < byteCount)
        #expect(inbound.byteCount == byteCount)
    }

    @Test("an inline payload past the resident threshold is archived and arrives mapped back")
    func oversizeInlineArrivesResident() async throws {
        let harness = TransferHarness(maxResidentInlineBytes: 4096)
        defer { harness.tearDown() }
        let payload = patternedBytes(count: 64 * 1024, multiplier: 11, offset: 1)
        let transferID: UInt64 = 0x61
        harness.push(
            transferID: transferID, generation: 6,
            plan: .init(uti: "public.png", filename: "clip.png", advertisedByteCount: payload.count),
            representation: .init(uti: "public.png", data: payload, filename: "clip.png"),
            isInline: true)
        try await settle(harness, transferID)

        let representation = try #require(harness.collector.representation(transferID))
        // Residency is an implementation detail: the pasteboard flavor is still
        // resident bytes (docs/CLIPBOARD.md §1).
        #expect(representation.inMemoryData == payload)
        let inbound = try #require(harness.collector.inboundMetrics.first)
        #expect(inbound.inbound?.streamedToDisk == true)
    }

    // MARK: - Integrity

    @Test("a byte flipped in transit fails the digest and delivers nothing")
    func corruptionInTransitFailsTheDigest() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let payload = patternedBytes(count: 32 * 1024, multiplier: 5, offset: 9)
        let transferID: UInt64 = 0x71
        let representation = ClipboardContent.Representation(
            uti: "public.utf8-plain-text", data: payload)
        harness.expect(
            transferID: transferID,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: payload.count))

        let outbox = harness.outbox
        let collector = harness.collector
        harness.openPull(transferID: transferID, generation: 7) { far, request in
            // A second socketpair between the sender and the receiver, with a
            // relay that changes one payload byte on the way — the only
            // corruption the transport itself cannot notice.
            guard let (senderEnd, relayEnd) = try? makeRawSocketPair() else {
                ClipboardDataConnection.end(fd: far)
                return
            }
            outbox.serve(
                transferID: request.transferID, generation: request.generation,
                representation: representation,
                maxAcceptByteCount: request.maxAcceptByteCount, isInline: true,
                isCurrent: { _ in true }, link: .accepted(senderEnd),
                onComplete: { collector.sendFinished(request.transferID, success: $0) })
            relayFlippingOneByte(from: relayEnd, to: far)
        }
        try await settle(harness, transferID)

        #expect(harness.collector.representation(transferID) == nil)
        let info = try await abortAfterSettling(harness)
        #expect(info.code == .digestMismatch)
        #expect(!info.isRetiring)
    }

    @Test("a stream that ends before its trailer is a truncation, not a payload")
    func truncatedStreamIsReported() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let transferID: UInt64 = 0x81
        harness.expect(
            transferID: transferID, plan: .init(uti: "public.data", advertisedByteCount: 4096))
        harness.openPull(transferID: transferID, generation: 8) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: false, isInline: true,
                totalBytes: 4096)
            try? ClipboardDataConnection.write(
                fd: far, patternedBytes(count: 1024, multiplier: 3, offset: 2))
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .sizeMismatch)
        #expect(harness.collector.representation(transferID) == nil)
    }

    // MARK: - Endings

    @Test(
        "every abort-trailer code reaches the pull as itself, retiring or not",
        arguments: [
            ClipboardStreamAbortCode.superseded, .cancelled, .userCancelled, .readError, .diskFull,
        ])
    func abortTrailerCodesResolve(code: ClipboardStreamAbortCode) async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let payload = patternedBytes(count: 2048, multiplier: 13, offset: 0)
        let transferID: UInt64 = 0x91
        harness.expect(
            transferID: transferID,
            plan: .init(uti: "public.data", advertisedByteCount: payload.count))
        harness.openPull(transferID: transferID, generation: 9) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: false, isInline: true,
                totalBytes: UInt64(payload.count))
            try? ClipboardDataConnection.write(fd: far, payload)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .aborted(rawCode: code.rawValue)), fd: far)
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == code)
        #expect(info.rawCode == code.rawValue)
        #expect(info.isRetiring == ClipboardStreamAbortCode.retiring.contains(code))
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("a supersession mid-stream retires the pull quietly and stops the send")
    func supersessionRetiresQuietly() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<24 {
            try Data(repeating: UInt8(index), count: 1024 * 1024)
                .write(to: source.appendingPathComponent("f\(index).bin"))
        }
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        // False from the second write on, so the transfer is already streaming
        // when the offer is retired.
        let writes = Box(0)
        let transferID: UInt64 = 0xA1
        harness.pull(
            transferID: transferID, generation: 10,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "source"),
            isCurrent: { _ in
                let seen = writes.value
                writes.value = seen + 1
                return seen < 1
            })
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .superseded)
        #expect(info.isRetiring)
        try await harness.collector.gate.wait { harness.collector.sendCount == 1 }
        #expect(harness.collector.sendOutcome(transferID) == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("a receiver that gives up retires the pull quietly and stops the send")
    func receiverCancelStopsTheSend() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        // Incompressible and far larger than anything that can cross between
        // the first progress report and the cancellation below, so the transfer
        // is certainly mid-stream when the receiver gives up.
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try randomBytes(count: 32 * 1024 * 1024)
            .write(to: source.appendingPathComponent("big.bin"))
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        let transferID: UInt64 = 0xB1
        // Cancel from inside the stream, on the first bytes released, so the
        // point the pull gives up at is the transfer's own rather than whatever
        // the runner scheduled next.
        let cancelled = Box(false)
        harness.onReceiveProgress.value = { [weak harness] _, _ in
            guard !cancelled.value else { return }
            cancelled.value = true
            harness?.inbox.cancel(transferID: transferID)
        }
        harness.pull(
            transferID: transferID, generation: 11,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "source"))
        try await settle(harness, transferID)
        try await harness.collector.gate.wait { harness.collector.sendCount == 1 }

        let info = try abort(harness)
        #expect(info.code == .cancelled)
        #expect(info.isRetiring)
        #expect(harness.collector.abortCount == 1)
        #expect(harness.collector.representation(transferID) == nil)
        // The peer's gesture, not a failure of ours: the send stops and reports
        // nothing.
        #expect(harness.collector.sendOutcome(transferID) == false)
        #expect(harness.collector.outboundMetrics.isEmpty)
    }

    @Test("a send onto a connection the peer has closed fails and reports no timing")
    func sendToAClosedConnectionReportsNoMetrics() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let (near, far) = try makeRawSocketPair()
        ClipboardDataConnection.end(fd: far)
        let transferID: UInt64 = 0xC1
        let collector = harness.collector
        harness.outbox.serve(
            transferID: transferID, generation: 12,
            representation: .init(uti: "public.utf8-plain-text", data: Data("hi".utf8)),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in true }, link: .accepted(near),
            onComplete: { collector.sendFinished(transferID, success: $0) })

        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == false)
        #expect(collector.outboundMetrics.isEmpty)
    }

    // MARK: - Opening the connection

    @Test("a second connection for a transfer already streaming is closed, not orphaned")
    func duplicateTransferIDClosesItsConnection() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector
        let transferID: UInt64 = 0x181
        // A key of its own for the duplicate's terminal, so an outcome recorded
        // for it cannot be mistaken for the running transfer's.
        let duplicateKey: UInt64 = 0x182

        // Past everything the socket can buffer, with nothing reading the peer
        // end yet: the first transfer is parked mid-payload, and registered —
        // the outbox records it before its queue hop — when the duplicate
        // arrives.
        let payload = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        let (first, firstPeer) = try makeRawSocketPair()
        defer { ClipboardDataConnection.end(fd: firstPeer) }
        harness.outbox.serve(
            transferID: transferID, generation: 24,
            representation: .init(uti: "public.data", data: payload),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in true }, link: .accepted(first),
            onComplete: { collector.sendFinished(transferID, success: $0) })

        let (second, secondPeer) = try makeRawSocketPair()
        defer { ClipboardDataConnection.end(fd: secondPeer) }
        harness.outbox.serve(
            transferID: transferID, generation: 24,
            representation: .init(uti: "public.data", data: Data("second".utf8)),
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount, isInline: true,
            isCurrent: { _ in true }, link: .accepted(second),
            onComplete: { collector.sendFinished(duplicateKey, success: $0) })

        // The refused link is given up as `serve` returns, so its peer reaches
        // EOF instead of parking on a connection nothing owns.
        #expect(try drainUntilPeerCloses(secondPeer).isEmpty)

        // The transfer already under way kept its own connection: draining it
        // releases the parked send, and every payload byte is there.
        let delivered = await offCooperativePool { (try? readToEnd(fd: firstPeer)) ?? Data() }
        #expect(delivered.count > payload.count)
        try await collector.gate.wait { collector.sendCount == 1 }
        #expect(collector.sendOutcome(transferID) == true)
        // The duplicate reported nothing: the id's one terminal is the running
        // transfer's to fire.
        #expect(collector.sendOutcome(duplicateKey) == nil)
    }

    @Test("a cancel landing before the connection opens closes the descriptor it was handed")
    func cancelBeforeOpenClosesTheAcceptedConnection() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let collector = harness.collector
        let transferID: UInt64 = 0x191
        let (accepted, peer) = try makeRawSocketPair()
        defer { ClipboardDataConnection.end(fd: peer) }

        // The window `ClipboardTransferInbox.start` opens between registering
        // the transfer and its queue hop: the cancel lands while the receiver
        // holds no descriptor to interrupt, which is what a session teardown or
        // a supersession during an accepted transfer produces.
        let receiver = harness.makeReceiver(
            transferID: transferID, generation: 25,
            plan: .init(uti: "public.utf8-plain-text"),
            source: .accepted(
                fd: accepted,
                reply: Kernova_V1_ClipboardTransferReply.with {
                    $0.transferID = transferID
                    $0.isInline = true
                }))
        receiver.cancel()
        receiver.start(
            onComplete: { collector.complete(transferID, $0) },
            onAbort: { collector.abort($0) })
        try await collector.gate.wait { collector.abortCount > 0 }

        let info = try abort(harness)
        #expect(info.code == .cancelled)
        #expect(info.isRetiring)
        #expect(collector.representation(transferID) == nil)
        // The descriptor the accept handed over is closed on the way out, so the
        // peer sees EOF rather than a connection nothing will ever read.
        #expect(try drainUntilPeerCloses(peer).isEmpty)
    }

    @Test("a dial that fails reports the failure instead of retiring the pull quietly")
    func failedDialReportsTheFailure() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let transferID: UInt64 = 0x1A1
        harness.expect(
            transferID: transferID, plan: .init(uti: "public.data", advertisedByteCount: 16))
        harness.inbox.open(
            transferID: transferID, generation: 26,
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount
        ) {
            throw DialFailure.refused("the data port refused admission")
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .sendFailed)
        // The pull that dialled is the only place this can be reported from, so
        // a retiring code would take the failure with it.
        #expect(!info.isRetiring)
        #expect(ClipboardTransferFailure.inboundPullAborted(info) == .transferFailed)
        #expect(info.message.contains("the data port refused admission"))
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("a request that cannot be written reports the failure the connection raised")
    func failedRequestWriteReportsTheFailure() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let transferID: UInt64 = 0x1B1
        harness.expect(
            transferID: transferID, plan: .init(uti: "public.data", advertisedByteCount: 16))
        // A connected descriptor whose peer is already gone: the dial succeeds
        // and the request has nowhere to land.
        let (near, far) = try makeRawSocketPair()
        ClipboardDataConnection.end(fd: far)
        harness.inbox.open(
            transferID: transferID, generation: 27,
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount
        ) { near }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .sendFailed)
        #expect(!info.isRetiring)
    }

    // MARK: - Refusals

    @Test(
        "a refusal reply resolves the pull with the code it names",
        arguments: [
            ClipboardStreamAbortCode.requestStale, .requestRange, .requestUTI, .requestCancelled,
            .superseded, .diskFull,
        ])
    func refusalRepliesResolveThePull(code: ClipboardStreamAbortCode) async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let transferID: UInt64 = 0xD1
        harness.expect(transferID: transferID, plan: .init(uti: "public.data"))
        harness.openPull(transferID: transferID, generation: 13) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? ClipboardDataConnection.writeFrame(
                .clipboardTransferRefusal(
                    transferID: request.transferID, code: code, message: "refused"),
                fd: far)
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == code)
        #expect(info.message == "refused")
        #expect(info.isRetiring == ClipboardStreamAbortCode.retiring.contains(code))
    }

    @Test("a sender that cannot meet the requester's ceiling refuses before any byte")
    func senderRefusesOverTheRequestersCeiling() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let file = scratch.appendingPathComponent("big.bin")
        try Data(repeating: 0x11, count: 8192).write(to: file)
        let transferID: UInt64 = 0xE1
        harness.pull(
            transferID: transferID, generation: 14,
            plan: .init(uti: "public.data", filename: "big.bin", advertisedByteCount: 8192),
            representation: .init(
                uti: "public.data", fileURL: file, byteCount: 8192, filename: "big.bin"),
            maxAcceptByteCount: 1024)
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .diskFull)
        #expect(harness.collector.representation(transferID) == nil)
    }

    // MARK: - Staging guards

    @Test("a volume with no room refuses the transfer before anything is staged")
    func diskFullPreflightRefusesTheTransfer() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }

        let file = scratch.appendingPathComponent("payload.bin")
        try Data(repeating: 0x22, count: 4096).write(to: file)
        let transferID: UInt64 = 0xF1
        harness.pull(
            transferID: transferID, generation: 15,
            plan: .init(uti: "public.data", filename: "payload.bin", advertisedByteCount: 4096),
            representation: .init(
                uti: "public.data", fileURL: file, byteCount: 4096, filename: "payload.bin"))
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .diskFull)
        #expect(info.neededBytes == 4096)
        #expect(info.availableBytes == 0)
    }

    @Test("a volume that fills mid-extract stops the transfer and removes the partial tree")
    func diskFullMidExtractStopsTheTransfer() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        // Room at the pre-flight, none once the extract is under way.
        let checks = Box(0)
        let harness = TransferHarness(
            freeSpaceProvider: { _ in
                let seen = checks.value
                checks.value = seen + 1
                return seen == 0 ? Int64(1 << 40) : 0
            }, extractPacingBytes: 4096)
        defer { harness.tearDown() }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try patternedBytes(count: 512 * 1024, multiplier: 17, offset: 4)
            .write(to: source.appendingPathComponent("a.bin"))
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        let transferID: UInt64 = 0x101
        harness.pull(
            transferID: transferID, generation: 16,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "source"))
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .diskFull)
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("a payload that outgrows what its offer advertised is refused as an overrun")
    func overCeilingExtractIsRefused() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness(minimumExtractAllowance: 4096, extractPacingBytes: 1024)
        defer { harness.tearDown() }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try patternedBytes(count: 256 * 1024, multiplier: 19, offset: 6)
            .write(to: source.appendingPathComponent("a.bin"))
        let transferID: UInt64 = 0x111
        // The offer claimed a tree far smaller than the one being sent, so the
        // extract's own guard is the only thing bounding it.
        harness.pull(
            transferID: transferID, generation: 17,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: 1024),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: 1024, filename: "source"))
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .sizeOverrun)
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("garbage in place of an archive is an extract failure, and leaves no tree")
    func garbagePayloadIsAnExtractFailure() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let transferID: UInt64 = 0x121
        harness.expect(
            transferID: transferID,
            plan: .init(uti: "public.data", filename: "a.bin", advertisedByteCount: 64))
        harness.openPull(transferID: transferID, generation: 18) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            let garbage = Data("not a valid archive at all".utf8)
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: true, isInline: false,
                totalBytes: 0)
            try? ClipboardDataConnection.write(fd: far, garbage)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: sha256(garbage))), fd: far)
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .extractError)
        #expect(harness.collector.representation(transferID) == nil)
    }

    @Test("an archive that unpacks to more than one file does not answer a file pull")
    func multiEntryArchiveIsAnInvalidFilePayload() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "one".write(
            to: source.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two".write(
            to: source.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        let transferID: UInt64 = 0x131
        // The pull expects one file; the peer sends a tree.
        harness.pull(
            transferID: transferID, generation: 19,
            plan: .init(uti: "public.data", filename: "one.txt", advertisedByteCount: 6),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: 6, filename: "source"))
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .payloadInvalid)
    }

    @Test("a sender that goes quiet trips the connection's own stall bound")
    func aSilentSenderTripsTheStallTimeout() async throws {
        let harness = TransferHarness(socketTimeout: 0.3)
        defer { harness.tearDown() }
        let transferID: UInt64 = 0x141
        harness.expect(
            transferID: transferID, plan: .init(uti: "public.data", advertisedByteCount: 4096))
        harness.openPull(transferID: transferID, generation: 20) { far, request in
            defer { ClipboardDataConnection.end(fd: far) }
            try? writeTransferReply(
                fd: far, transferID: request.transferID, isArchive: false, isInline: true,
                totalBytes: 4096)
            // Holds the connection open and sends nothing more; the read below
            // returns only once the receiver has given up and closed its end,
            // so nothing here sleeps.
            var parked = [UInt8](repeating: 0, count: 1)
            _ = parked.withUnsafeMutableBytes { raw in
                try? ClipboardDataConnection.read(fd: far, into: raw)
            }
        }
        try await settle(harness, transferID)

        let info = try abort(harness)
        #expect(info.code == .stallTimeout)
    }

    // MARK: - Progress and metrics

    @Test("a folder's progress climbs in payload units, not in compressed wire bytes")
    func folderProgressIsInPayloadUnits() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // Part incompressible, so the wire carries enough to report progress
        // several times over, and part not, so payload units and wire bytes are
        // far enough apart that a figure in the wrong one is unmistakable.
        for index in 0..<8 {
            var payload = try randomBytes(count: 256 * 1024)
            payload.append(Data(repeating: 0x33, count: 768 * 1024))
            try payload.write(to: source.appendingPathComponent("f\(index).bin"))
        }
        let estimate = ClipboardArchive.estimatedByteCount(at: source)
        let transferID: UInt64 = 0x151
        harness.pull(
            transferID: transferID, generation: 21,
            plan: .init(
                uti: ClipboardArchive.directoryUTI, filename: "source",
                extractsDirectoryNamed: "source", advertisedByteCount: estimate),
            representation: .init(
                directorySourceURL: source, estimatedByteCount: estimate, filename: "source"))
        try await settle(harness, transferID)

        let inbound = try #require(harness.collector.inboundMetrics.first)
        let received = harness.collector.receiveProgressReports
        #expect(received.count >= 2)
        #expect(received.map(\.bytes) == received.map(\.bytes).sorted())
        let highestReceived = try #require(received.map(\.bytes).max())
        #expect(highestReceived > inbound.wireByteCount)
        // An archive leaves the tracker on the offer's own figure.
        #expect(received.allSatisfy { $0.total == 0 })

        let sent = harness.collector.sendProgressReports
        #expect(sent.count >= 2)
        let highestSent = try #require(sent.map(\.bytes).max())
        #expect(highestSent > inbound.wireByteCount)
        #expect(sent.allSatisfy { $0.total == 0 })
    }

    @Test("both directions report the transfer, in the same units and without chunk stages")
    func metricsDescribeBothDirections() async throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let payload = Data(repeating: 0x44, count: 1024 * 1024)
        let file = scratch.appendingPathComponent("payload.bin")
        try payload.write(to: file)
        let transferID: UInt64 = 0x161
        harness.pull(
            transferID: transferID, generation: 22,
            plan: .init(
                uti: "public.data", filename: "payload.bin", advertisedByteCount: payload.count),
            representation: .init(
                uti: "public.data", fileURL: file, byteCount: payload.count,
                filename: "payload.bin"))
        try await settle(harness, transferID)
        try await harness.collector.gate.wait { !harness.collector.outboundMetrics.isEmpty }

        let inbound = try #require(harness.collector.inboundMetrics.first)
        #expect(inbound.byteCount == payload.count)
        #expect(inbound.inbound?.streamedToDisk == true)
        #expect(inbound.inbound?.streamingDuration != nil)

        let outbound = try #require(harness.collector.outboundMetrics.first)
        let detail = try #require(outbound.outbound)
        #expect(detail.isArchived)
        #expect(detail.timeToFirstByte != nil)
        #expect(detail.sourceWait >= 0)
        // The chunk-and-credit stages belong to a transport this one replaced.
        #expect(!outbound.logSummary.contains("chunks"))
        #expect(!outbound.logSummary.contains("credit"))
        // Both sides state the payload in the same unit, so the two lines
        // compare as they stand.
        #expect(outbound.byteCount == inbound.byteCount)
    }

    // MARK: - Header orders

    @Test("the dialling side writes the first frame, whichever direction it is receiving")
    func bothHeaderOrdersOpenTheConnection() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }
        let payload = Data("both orders".utf8)

        // Receiver dials: request, then the sender's reply, then the bytes.
        let pullID: UInt64 = 0x171
        let sawRequest = Box(false)
        harness.expect(
            transferID: pullID,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: payload.count))
        let outbox = harness.outbox
        let collector = harness.collector
        harness.openPull(transferID: pullID, generation: 23) { far, request in
            sawRequest.value = request.transferID == pullID
            outbox.serve(
                transferID: request.transferID, generation: request.generation,
                representation: .init(uti: "public.utf8-plain-text", data: payload),
                maxAcceptByteCount: request.maxAcceptByteCount, isInline: true,
                isCurrent: { _ in true }, link: .accepted(far),
                onComplete: { collector.sendFinished(request.transferID, success: $0) })
        }
        try await settle(harness, pullID)
        #expect(sawRequest.value)
        #expect(harness.collector.representation(pullID)?.inMemoryData == payload)

        // Sender dials: the reply is the first frame, and the bytes follow it.
        let pushHarness = TransferHarness()
        defer { pushHarness.tearDown() }
        let pushID: UInt64 = 0x172
        pushHarness.push(
            transferID: pushID, generation: 23,
            plan: .init(uti: "public.utf8-plain-text", advertisedByteCount: payload.count),
            representation: .init(uti: "public.utf8-plain-text", data: payload), isInline: true)
        try await settle(pushHarness, pushID)
        #expect(pushHarness.collector.representation(pushID)?.inMemoryData == payload)
    }

    // MARK: - Helpers

    /// The abort a transfer reported, waiting for it if the completion check
    /// resolved first.
    private func abortAfterSettling(_ harness: TransferHarness) async throws
        -> ClipboardStreamAbortInfo
    {
        try await harness.collector.gate.wait { harness.collector.abortCount > 0 }
        return try #require(harness.collector.abortInfos.first)
    }
}
