import CryptoKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import Kernova

/// Unit tests for the host side of dragging files onto the VM display: the offer
/// it announces, the bytes it streams when the guest pulls, and what it reports
/// when a drop is cancelled or the guest cannot finish it.
@Suite("VsockDropService")
@MainActor
struct VsockDropServiceTests {
    // MARK: - Harness

    /// A socketpair, the service under test on one end, and a frame recorder
    /// standing in for the guest agent on the other.
    @MainActor
    private final class Harness {
        let service: VsockDropService
        let guest: VsockChannel
        let issueCenter = ClipboardIssueCenter()
        let progressCenter = ClipboardProgressCenter()
        let instanceID = UUID()
        let recorder: FrameRecorder
        private let host: VsockChannel

        init(directoryByteCount: @escaping @Sendable (URL) -> Int = { _ in 0 }) throws {
            let (hostFd, guestFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            guest = VsockChannel(fileDescriptor: guestFd)
            host.start()
            guest.start()
            recorder = FrameRecorder(channel: guest)
            service = VsockDropService(
                channel: host, label: "Drop VM", instanceID: instanceID,
                // Zeroed so a transfer's readout is on screen while it runs.
                progressRevealDelay: 0, progressIdleLinger: 0,
                directoryByteCount: directoryByteCount,
                // Inline, so the folder walk needs no cross-thread wait.
                runOffMainActor: { work in work() },
                progressCenter: progressCenter, issueCenter: issueCenter)
            service.start()
        }

        func tearDown() {
            recorder.cancel()
            service.stop()
            guest.close()
        }

        var issue: ClipboardTransferIssue? { issueCenter.latestByInstance[instanceID]?.issue }
    }

    /// Collects frames arriving on the guest end, with a gate to await them.
    @MainActor
    private final class FrameRecorder {
        var frames: [Frame] = []
        let recorded = AsyncGate()
        private var consumeTask: Task<Void, Never>?

        init(channel: VsockChannel) {
            consumeTask = Task { @MainActor [weak self] in
                do {
                    for try await frame in channel.incoming {
                        self?.frames.append(frame)
                        self?.recorded.notify()
                    }
                } catch {
                    // Stream ended; tests assert on what was recorded.
                }
            }
        }

        func cancel() { consumeTask?.cancel() }
        deinit { consumeTask?.cancel() }

        var offers: [Kernova_V1_DropOffer] {
            frames.compactMap {
                if case .dropOffer(let offer) = $0.payload { return offer }
                return nil
            }
        }

        var releases: [Kernova_V1_DropRelease] {
            frames.compactMap {
                if case .dropRelease(let release) = $0.payload { return release }
                return nil
            }
        }

        var begins: [Kernova_V1_ClipboardStreamBegin] {
            frames.compactMap {
                if case .clipboardStreamBegin(let begin) = $0.payload { return begin }
                return nil
            }
        }

        var aborts: [Kernova_V1_ClipboardStreamAbort] {
            frames.compactMap {
                if case .clipboardStreamAbort(let abort) = $0.payload { return abort }
                return nil
            }
        }

        func chunkBytes(for transferID: UInt64) -> Data {
            var data = Data()
            for frame in frames {
                if case .clipboardChunk(let chunk) = frame.payload, chunk.transferID == transferID {
                    data.append(chunk.data)
                }
            }
            return data
        }

        func end(for transferID: UInt64) -> Kernova_V1_ClipboardStreamEnd? {
            for frame in frames {
                if case .clipboardStreamEnd(let end) = frame.payload, end.transferID == transferID {
                    return end
                }
            }
            return nil
        }

        func wait(until predicate: @escaping () -> Bool) async throws {
            try await recorded.wait(until: predicate)
        }
    }

    // MARK: - Fixtures

    /// A fresh directory under the temp root, removed by the caller.
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VsockDropServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(in directory: URL, named name: String, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// The id the guest mints for representation `index` of `generation` — the
    /// guest is the receiver, so the direction bit stays clear.
    private func transferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: false)
    }

    private func makeRequest(generation: UInt64, transferID: UInt64, uti: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.transferID = transferID
            $0.uti = uti
            $0.maxAcceptByteCount = ClipboardStreamTuning.unlimitedAcceptByteCount
        }
        return frame
    }

    /// The receiver's go-signal plus credit for the whole payload.
    private func makeAck(transferID: UInt64, consumed: UInt64 = 0) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAck = Kernova_V1_ClipboardStreamAck.with {
            $0.transferID = transferID
            $0.bytesConsumed = consumed
            $0.windowBytes = UInt64(ClipboardStreamTuning.defaultWindowBytes)
        }
        return frame
    }

    private func makeComplete(
        generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
        code: ClipboardErrorCode? = nil
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropComplete = Kernova_V1_DropComplete.with {
            $0.generation = generation
            $0.outcome = outcome
            if let code {
                $0.code = code.rawValue
                $0.message = "detail the host must not render"
            }
        }
        return frame
    }

    // MARK: - Offering

    @Test("a drop offers one item per file, with the name and stat'd size")
    func offersEveryDroppedFile() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try makeFile(in: scratch, named: "notes.txt", bytes: Data(repeating: 0x41, count: 12))
        let second = try makeFile(in: scratch, named: "data.bin", bytes: Data(repeating: 0x42, count: 34))

        #expect(harness.service.startDrop(urls: [first, second]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        let offer = try #require(harness.recorder.offers.first)
        #expect(offer.generation == 1)
        #expect(offer.repInfo.map(\.filename) == ["notes.txt", "data.bin"])
        #expect(offer.repInfo.map(\.byteCount) == [12, 34])
        // A drop always lands as a file; nothing about it is pasteboard-inline.
        #expect(offer.repInfo.allSatisfy { !$0.isInline })
        #expect(offer.repInfo.allSatisfy { !$0.isDirectory })
    }

    @Test("a dropped folder is offered as a directory carrying its stat-walk estimate")
    func offersAFolderWithItsEstimate() async throws {
        let harness = try Harness(directoryByteCount: { _ in 4_096 })
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(harness.service.startDrop(urls: [folder]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        let rep = try #require(harness.recorder.offers.first?.repInfo.first)
        #expect(rep.filename == "Photos")
        #expect(rep.isDirectory)
        #expect(rep.byteCount == 4_096)
    }

    @Test("two drops are independent jobs under their own generations")
    func secondDropDoesNotSupersedeTheFirst() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { harness.recorder.offers.count == 2 }

        #expect(harness.recorder.offers.map(\.generation) == [1, 2])
        // Nothing retires the first drop: the user asked for both sets of files.
        #expect(harness.recorder.releases.isEmpty)
    }

    @Test("a drop of items that cannot be read is refused, and says so")
    func refusesUnreadableItems() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        #expect(!harness.service.startDrop(urls: [missing]))
        #expect(harness.recorder.offers.isEmpty)
        // The gesture happened on this Mac and produced nothing, so the silence
        // is explained here.
        #expect(harness.issue != nil)
    }

    // MARK: - Serving the guest's pulls

    @Test("the guest's request streams the dropped file as a one-entry archive")
    func streamsTheRequestedFile() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let payload = Data((0..<2_048).map { UInt8($0 & 0xFF) })
        let file = try makeFile(in: scratch, named: "blob.bin", bytes: payload)

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        let xid = transferID(generation: 1, repIndex: 0)
        let uti = try #require(harness.recorder.offers.first?.repInfo.first?.uti)
        try harness.guest.send(makeRequest(generation: 1, transferID: xid, uti: uti))
        try await harness.recorder.wait { !harness.recorder.begins.isEmpty }

        let begin = try #require(harness.recorder.begins.first)
        #expect(begin.transferID == xid)
        #expect(begin.filename == "blob.bin")
        #expect(begin.isArchive)
        // An archive's compressed size isn't known until its last byte.
        #expect(begin.totalBytes == 0)
        #expect(!begin.isInline)

        // The first ack is the sender's go-signal.
        try harness.guest.send(makeAck(transferID: xid))
        try await harness.recorder.wait { harness.recorder.end(for: xid) != nil }

        let wire = harness.recorder.chunkBytes(for: xid)
        let unpacked = try extractedClipboardArchive(wire)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["blob.bin"])
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("blob.bin")) == payload)

        let end = try #require(harness.recorder.end(for: xid))
        #expect(end.totalBytes == UInt64(wire.count))
        #expect(end.sha256 == Data(SHA256.hash(data: wire)))
    }

    @Test("the guest's request streams a dropped folder as its tree archive")
    func streamsTheRequestedFolder() async throws {
        let harness = try Harness(directoryByteCount: { _ in 8 })
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try makeFile(in: folder, named: "one.txt", bytes: Data("hello".utf8))

        #expect(harness.service.startDrop(urls: [folder]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        let xid = transferID(generation: 1, repIndex: 0)
        let rep = try #require(harness.recorder.offers.first?.repInfo.first)
        #expect(rep.isDirectory)
        try harness.guest.send(makeRequest(generation: 1, transferID: xid, uti: rep.uti))
        try await harness.recorder.wait { !harness.recorder.begins.isEmpty }

        let begin = try #require(harness.recorder.begins.first)
        #expect(begin.isArchive)
        #expect(begin.totalBytes == 0)

        try harness.guest.send(makeAck(transferID: xid))
        try await harness.recorder.wait { harness.recorder.end(for: xid) != nil }

        let wire = harness.recorder.chunkBytes(for: xid)
        // The tree's entries are relative to the folder, so its own name is not
        // in the archive — the receiver supplies it.
        let unpacked = try extractedClipboardArchive(wire, named: "Photos")
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(unpacked.lastPathComponent == "Photos")
        #expect(
            try Data(contentsOf: unpacked.appendingPathComponent("one.txt"))
                == Data("hello".utf8))

        let end = try #require(harness.recorder.end(for: xid))
        #expect(end.totalBytes == UInt64(wire.count))
        #expect(end.sha256 == Data(SHA256.hash(data: wire)))
    }

    @Test("a request naming an unknown drop, index, or type is rejected rather than served")
    func rejectsMalformedRequests() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        let uti = try #require(harness.recorder.offers.first?.repInfo.first?.uti)

        // A generation no drop was ever offered under.
        try harness.guest.send(
            makeRequest(
                generation: 99, transferID: transferID(generation: 99, repIndex: 0), uti: uti))
        try await harness.recorder.wait { !harness.recorder.aborts.isEmpty }
        #expect(harness.recorder.aborts.first?.code == ClipboardStreamAbortCode.requestStale.rawValue)

        // An index past the offer's items.
        try harness.guest.send(
            makeRequest(
                generation: 1, transferID: transferID(generation: 1, repIndex: 5), uti: uti))
        try await harness.recorder.wait { harness.recorder.aborts.count >= 2 }
        #expect(harness.recorder.aborts[1].code == ClipboardStreamAbortCode.requestRange.rawValue)

        // The right item, the wrong type.
        try harness.guest.send(
            makeRequest(
                generation: 1, transferID: transferID(generation: 1, repIndex: 0),
                uti: "public.mpeg-4"))
        try await harness.recorder.wait { harness.recorder.aborts.count >= 3 }
        #expect(harness.recorder.aborts[2].code == ClipboardStreamAbortCode.requestUTI.rawValue)
        // Nothing was streamed for any of them.
        #expect(harness.recorder.begins.isEmpty)
    }

    // MARK: - Cancelling

    @Test("cancelling releases the drop and stops the transfer in flight")
    func cancelReleasesAndAborts() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(
            in: scratch, named: "big.bin", bytes: Data(repeating: 0x5A, count: 512 * 1_024))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        let xid = transferID(generation: 1, repIndex: 0)
        let uti = try #require(harness.recorder.offers.first?.repInfo.first?.uti)
        try harness.guest.send(makeRequest(generation: 1, transferID: xid, uti: uti))
        try await harness.recorder.wait { !harness.recorder.begins.isEmpty }
        // Deliberately never acked: the transfer parks on credit, which is where
        // a cancel has to reach it.

        harness.service.cancelDrop(generation: 1)

        try await harness.recorder.wait { !harness.recorder.releases.isEmpty }
        #expect(harness.recorder.releases.first?.generation == 1)
        try await harness.recorder.wait {
            harness.recorder.aborts.contains { $0.code == ClipboardStreamAbortCode.superseded.rawValue }
        }
        // A cancel is not a failure: nothing is raised on either surface.
        #expect(harness.issue == nil)
    }

    @Test("cancelling a drop that is already over does nothing")
    func cancelAfterCompletionIsANoOp() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        try harness.guest.send(makeComplete(generation: 1, outcome: .completed))
        try await Task.sleep(for: .milliseconds(50))

        harness.service.cancelDrop(generation: 1)
        harness.service.cancelDrop(generation: 1)

        #expect(harness.recorder.releases.isEmpty)
        #expect(harness.issue == nil)
    }

    // MARK: - The guest's verdict

    @Test("a completed drop raises nothing")
    func completionIsSilent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        try harness.guest.send(makeComplete(generation: 1, outcome: .completed))
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.issue == nil)
    }

    @Test("a failed drop raises an issue whose sentence the host composes")
    func failureRaisesAHostComposedIssue() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        try harness.guest.send(
            makeComplete(generation: 1, outcome: .failed, code: .dropDownloadsDenied))
        try await waitUntil { harness.issue != nil }

        let issue = try #require(harness.issue)
        let message = issue.displayMessage(pasteLimitBytes: ClipboardPasteLimit.defaultBytes)
        #expect(message.contains("Downloads"))
        // The guest's own message text never reaches a surface.
        #expect(!message.contains("detail the host must not render"))
        // The specific code reaches every surface, so the dropdown line names
        // the same outcome the notice body does rather than the generic one.
        #expect(issue.menuLineText == "Drop: the VM's Downloads folder is off limits")
    }

    @Test("a drop that fails partway never claims the files it already moved weren't saved")
    func failureCopyDoesNotDenyPartialProgress() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        try harness.guest.send(makeComplete(generation: 1, outcome: .failed, code: .dropDiskFull))
        try await waitUntil { harness.issue != nil }

        // The guest moves each file as it lands, so a batch that fails on file 3
        // leaves 1 and 2 in Downloads. A message saying nothing was saved would
        // send the user looking for files that are there.
        let message = try #require(harness.issue).displayMessage(
            pasteLimitBytes: ClipboardPasteLimit.defaultBytes)
        #expect(message.contains("disk space"))
        #expect(!message.contains("weren't saved"))
    }

    // MARK: - Teardown

    @Test("stopping clears the readout and answers for a drop still in flight")
    func stopReportsAbandonedDrops() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        #expect(!harness.service.isConnected)
        #expect(harness.service.transferProgress == nil)
        #expect(harness.progressCenter.materializationProgress == nil)
        // The files never landed and the gesture was made here, so the silence
        // is owed an answer.
        #expect(harness.issue != nil)
    }

    @Test("stopping after a cancelled drop reports nothing — the user already knows")
    func stopIsSilentAfterACancel() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }
        harness.service.cancelDrop(generation: 1)

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        #expect(harness.issue == nil)
    }

    @Test("the channel ending settles the service, so the display stops offering drops")
    func channelEndSettlesTheService() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.wait { !harness.recorder.offers.isEmpty }

        // The guest's drop client closes this channel on every control
        // reconnect. Nothing calls `stop()` for that, so the service has to
        // settle itself or it keeps advertising a drop it cannot send.
        harness.recorder.cancel()
        harness.guest.close()

        try await waitForChange { !harness.service.isConnected }
        #expect(!harness.service.startDrop(urls: [file]))
        #expect(harness.service.transferProgress == nil)
        #expect(harness.progressCenter.materializationProgress == nil)
        // The drop in flight when the channel went is owed an answer.
        #expect(harness.issue != nil)
    }

    @Test("a folder still being sized when the channel goes reports the interruption")
    func pendingFolderWalkReportsInterruption() async throws {
        let harness = try Harness(directoryByteCount: { _ in 4_096 })
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The drop is accepted and its offer deferred behind the size walk. This
        // test is main-actor bound, so the walk's completion hop cannot run
        // until the awaits below — the same window a slow real walk opens.
        #expect(harness.service.startDrop(urls: [folder]))
        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        // No job was ever registered, so `settle()` had nothing to report: only
        // the discarded walk can account for the drop the user made.
        try await waitForChange { harness.issue != nil }
        #expect(harness.recorder.offers.isEmpty)
    }

    @Test("a drop is refused once the service has stopped")
    func refusesADropAfterStop() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        #expect(!harness.service.startDrop(urls: [file]))
    }
}
