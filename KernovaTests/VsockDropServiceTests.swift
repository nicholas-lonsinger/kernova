import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import Kernova

/// Unit tests for the host side of dragging files onto the VM display: the offer
/// it announces, the bytes it streams when the guest pulls, and what it reports
/// when a drop is cancelled or the guest cannot finish it.
@Suite("VsockDropService", .admissionGated)
@MainActor
struct VsockDropServiceTests {
    // MARK: - Harness

    /// A socketpair, the service under test on one end, and a frame recorder
    /// standing in for the guest agent on the other.
    ///
    /// Main-bound because it owns `@MainActor` production types — the service
    /// and the transfer report — rather than playing the peer itself; the frame
    /// recorder that does is already off-actor, and `pull` runs off-main
    /// (docs/TESTING.md).
    @MainActor
    private final class Harness {
        let service: VsockDropService
        let guest: VsockChannel
        /// This VM's transfer report, as every surface reads it.
        let reports = ClipboardTransferReports()
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
                channel: host, label: "Drop VM", reporter: reports.reporter,
                // Zeroed so a transfer's readout is on screen while it runs.
                progressRevealDelay: 0, progressIdleGap: 0,
                directoryByteCount: directoryByteCount,
                // Inline, so the folder walk needs no cross-thread wait.
                runOffMainActor: { work in work() })
            service.start()
        }

        func tearDown() {
            recorder.cancel()
            service.stop()
            guest.close()
        }

        /// Pulls one offered item the way the guest agent does: a data connection
        /// of its own opening with the request — a macOS guest only ever dials —
        /// then the reply, the payload and the trailer that answer it.
        ///
        /// The pull blocks until the transfer ends, so it runs off the suite's
        /// main actor; the service streams onto the connection from there.
        func pull(generation: UInt64, transferID: UInt64, uti: String) async throws
            -> ReceivedTransfer
        {
            let (peerEnd, hostEnd) = try makeRawSocketPair()
            service.acceptDataConnection(fd: hostEnd)
            let received = await offCooperativePool {
                try? pullTransfer(
                    fd: peerEnd, generation: generation, transferID: transferID, uti: uti)
            }
            return try #require(
                received, "The drop answered transfer \(transferID) with nothing readable")
        }

        /// The refusal standing on this VM's report, or `nil` when none is.
        var failure: ClipboardTransferFailure? { reports.failure }

        /// The wording every surface renders for the standing refusal.
        var wording: ClipboardTransferWording? {
            reports.finish.flatMap { ClipboardTransferWording.wording(for: $0, vmName: "Drop VM") }
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

    /// The guest's own sentence, which the host composes over rather than
    /// renders.
    private let hiddenGuestMessage = "detail the host must not render"

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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let offer = try #require(harness.recorder.dropOffers.first)
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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let rep = try #require(harness.recorder.dropOffers.first?.repInfo.first)
        #expect(rep.filename == "Photos")
        #expect(rep.isDirectory)
        #expect(rep.byteCount == 4_096)
    }

    @Test("a drop of items that cannot be read is refused, and says so")
    func refusesUnreadableItems() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        #expect(!harness.service.startDrop(urls: [missing]))
        #expect(harness.recorder.dropOffers.isEmpty)
        // The gesture happened on this Mac and produced nothing, so the silence
        // is explained here.
        #expect(harness.failure != nil)
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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let xid = transferID(generation: 1, repIndex: 0)
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let received = try await harness.pull(generation: 1, transferID: xid, uti: uti)

        #expect(received.reply.transferID == xid)
        #expect(received.reply.isArchive)
        // An archive's compressed size isn't known until its last byte.
        #expect(received.reply.totalBytes == 0)
        #expect(!received.reply.isInline)

        let wire = received.payload
        let unpacked = try extractedClipboardArchive(wire)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        // Nothing on the connection repeats the offer's name: the archive's one
        // entry is what lands the file under it.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["blob.bin"])
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("blob.bin")) == payload)

        // The trailer's digest is taken over exactly the bytes that crossed.
        #expect(
            received.trailer == ClipboardTransferTrailer(ending: .complete(digest: sha256(wire))))
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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let xid = transferID(generation: 1, repIndex: 0)
        let rep = try #require(harness.recorder.dropOffers.first?.repInfo.first)
        #expect(rep.isDirectory)
        let received = try await harness.pull(generation: 1, transferID: xid, uti: rep.uti)

        #expect(received.reply.transferID == xid)
        #expect(received.reply.isArchive)
        #expect(received.reply.totalBytes == 0)

        let wire = received.payload
        // The tree's entries are relative to the folder, so its own name is not
        // in the archive — the receiver supplies it.
        let unpacked = try extractedClipboardArchive(wire, named: "Photos")
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(unpacked.lastPathComponent == "Photos")
        #expect(
            try Data(contentsOf: unpacked.appendingPathComponent("one.txt"))
                == Data("hello".utf8))

        #expect(
            received.trailer == ClipboardTransferTrailer(ending: .complete(digest: sha256(wire))))
    }

    // MARK: - Cancelling

    @Test("cancelling a drop that is already over does nothing")
    func cancelAfterCompletionIsANoOp() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        // The readout is the only handle a Cancel has, and only a running one
        // carries it — so the guest's pull is what puts one on screen.
        let xid = transferID(generation: 1, repIndex: 0)
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(generation: 1, transferID: xid, uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.wait { harness.reports.runningSnapshot == nil }

        harness.reports.reporter.cancelRunning()
        harness.reports.reporter.cancelRunning()

        #expect(harness.recorder.dropReleases.isEmpty)
        #expect(harness.failure == nil)
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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.failure == nil)
    }

    @Test("a failed drop raises an issue whose sentence the host composes")
    func failureRaisesAHostComposedIssue() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try harness.guest.send(
            makeDropCompleteFrame(
                generation: 1, outcome: .failed, code: .dropDownloadsDenied,
                message: hiddenGuestMessage))
        try await harness.reports.waitForFailure()

        let wording = try #require(harness.wording)
        #expect(wording.message.contains("Downloads"))
        // The guest's own message text never reaches a surface.
        #expect(!wording.message.contains(hiddenGuestMessage))
        // The specific code reaches every surface, so the dropdown line names
        // the same outcome the notice body does rather than the generic one.
        #expect(wording.menuLine == "Drop: the VM's Downloads folder is off limits")
    }

    @Test("a drop that fails partway never claims the files it already moved weren't saved")
    func failureCopyDoesNotDenyPartialProgress() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try harness.guest.send(
            makeDropCompleteFrame(
                generation: 1, outcome: .failed, code: .dropDiskFull, message: hiddenGuestMessage))
        try await harness.reports.waitForFailure()

        // The guest moves each file as it lands, so a batch that fails on file 3
        // leaves 1 and 2 in Downloads. A message saying nothing was saved would
        // send the user looking for files that are there.
        let message = try #require(harness.wording).message
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
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        #expect(!harness.service.isConnected)
        // The files never landed and the gesture was made here, so the silence
        // is owed an answer — and that answer, not a stuck bar, is the readout.
        try await harness.reports.waitForFailure()
        #expect(harness.reports.runningSnapshot == nil)
    }

    @Test("stopping after a cancelled drop reports nothing — the user already knows")
    func stopIsSilentAfterACancel() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        // The user's Cancel comes off the running readout, which the guest's
        // first pull is what raises.
        let xid = transferID(generation: 1, repIndex: 0)
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(generation: 1, transferID: xid, uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }
        harness.reports.reporter.cancelRunning()
        try await harness.recorder.waitForFrames { !harness.recorder.dropReleases.isEmpty }

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        #expect(harness.failure == nil)
    }

    @Test("the channel ending settles the service, so the display stops offering drops")
    func channelEndSettlesTheService() async throws {
        let harness = try Harness()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        // The guest's drop client closes this channel on every control
        // reconnect. Nothing calls `stop()` for that, so the service has to
        // settle itself or it keeps advertising a drop it cannot send.
        harness.recorder.cancel()
        harness.guest.close()

        try await waitForChange { !harness.service.isConnected }
        #expect(!harness.service.startDrop(urls: [file]))
        // The drop in flight when the channel went is owed an answer.
        try await harness.reports.waitForFailure()
        #expect(harness.reports.runningSnapshot == nil)
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
        try await harness.reports.waitForFailure()
        #expect(harness.recorder.dropOffers.isEmpty)
    }

    @Test("a control-plane payload on the drop channel closes it and settles the service")
    func wrongPortPayloadSettlesTheService() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello()
        try harness.guest.send(frame)

        // The endpoint closes the channel itself, so nothing else will tell the
        // service — and a service left connected keeps offering the display a
        // drop it cannot send.
        try await waitForChange { !harness.service.isConnected }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))
        #expect(!harness.service.startDrop(urls: [file]))
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

/// Drop-side readers over the shared ``FrameRecorder``.
extension FrameRecorder {
    /// Every recorded `DropOffer`, in arrival order.
    fileprivate var dropOffers: [Kernova_V1_DropOffer] {
        frames.compactMap {
            if case .dropOffer(let offer) = $0.payload { return offer }
            return nil
        }
    }

    /// Every recorded `DropRelease`, in arrival order.
    fileprivate var dropReleases: [Kernova_V1_DropRelease] {
        frames.compactMap {
            if case .dropRelease(let release) = $0.payload { return release }
            return nil
        }
    }
}
