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

        init(
            // Zeroed so a transfer's readout is on screen while it runs; a test
            // about what a drop *finishing inside the gate* leaves behind raises
            // it past anything the run can reach.
            progressRevealDelay: TimeInterval = 0,
            directoryByteCount: @escaping @Sendable (URL) -> Int = { _ in 0 },
            // Inline, so reading the items needs no cross-thread wait.
            runOffMainActor: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
                work()
            },
            scheduleDropDeadline:
                @escaping @Sendable (
                    TimeInterval, @escaping @MainActor @Sendable () -> Void
                ) -> Void = ClipboardOutboundOffers.scheduleOnMainQueue
        ) throws {
            let (hostFd, guestFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            guest = VsockChannel(fileDescriptor: guestFd)
            host.start()
            guest.start()
            recorder = FrameRecorder(channel: guest)
            service = VsockDropService(
                channel: host, label: "Drop VM", reporter: reports.reporter,
                progressRevealDelay: progressRevealDelay, progressIdleGap: 0,
                directoryByteCount: directoryByteCount,
                runOffMainActor: runOffMainActor,
                scheduleDropDeadline: scheduleDropDeadline)
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

        /// The note a drop that skipped `count` of its items raises.
        func skippedNote(count: Int = 1) -> String {
            count == 1
                ? "One item couldn\u{2019}t be read, so it wasn\u{2019}t sent to the VM. The rest were."
                : "\(count) items couldn\u{2019}t be read, so they weren\u{2019}t sent to the VM. The rest were."
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

    /// A path with nothing at the end of it, which a drag can only find out
    /// about once the off-main pass stats it.
    private func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    }

    private func makeFile(in directory: URL, named name: String, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A symlink at `name` pointing at `destination`, which need not exist.
    private func makeSymlink(in directory: URL, named name: String, to destination: URL) throws
        -> URL
    {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// Takes every permission off `url`, the way a file the user cannot open
    /// arrives in a drag.
    private func makeUnopenable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path)
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

    @Test("a drop of items that cannot be read offers nothing, and says so")
    func refusesUnreadableItems() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        // Taken on: whether an item can be read is only known once the off-main
        // pass has stat'd it, which is after the drag session has ended.
        #expect(harness.service.startDrop(urls: [missingFileURL()]))
        // The gesture happened on this Mac and produced nothing, so the silence
        // is explained here.
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .itemsUnreadable)
        #expect(harness.recorder.dropOffers.isEmpty)
    }

    @Test("a second drag that can read nothing raises its own refusal, not an echo")
    func aRepeatedUnreadableDragIsAnnouncedAgain() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(harness.service.startDrop(urls: [missingFileURL()]))
        try await harness.reports.waitForFailure()
        let first = try #require(harness.reports.finish)
        #expect(first.failure == .itemsUnreadable)

        // A second drag fails exactly as the first did. Nothing was ever
        // offered, so no operation measured either one — the drag itself is
        // what says this is a separate gesture owed its own message.
        #expect(harness.service.startDrop(urls: [missingFileURL()]))
        try await harness.reports.wait { harness.reports.finish?.date != first.date }
        #expect(harness.failure == .itemsUnreadable)
        #expect(harness.recorder.dropOffers.isEmpty)
    }

    @Test("an empty drag is refused outright")
    func refusesAnEmptyDrag() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(!harness.service.startDrop(urls: []))
        #expect(harness.failure == nil)
    }

    @Test("a mixed drop sends the readable items and names what it left out")
    func partiallyUnreadableDropReportsTheSkippedItems() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let readable = try makeFile(
            in: scratch, named: "notes.txt", bytes: Data(repeating: 0x41, count: 12))
        let missing = scratch.appendingPathComponent("gone-\(UUID().uuidString).bin")

        #expect(harness.service.startDrop(urls: [readable, missing]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        // The readable item still goes, so the drop is not all-or-nothing…
        let offer = try #require(harness.recorder.dropOffers.first)
        #expect(offer.repInfo.map(\.filename) == ["notes.txt"])
        // …and the one that didn't is said out loud rather than logged, in the
        // verdict that closes the gesture.
        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()
        let wording = try #require(harness.wording)
        #expect(wording.headline == "Some files not copied to \u{201C}Drop VM\u{201D}.")
        #expect(wording.message.contains("One item"))
        #expect(wording.menuLine == "Drop: some files weren't sent")
    }

    @Test("a link with nothing at the end of it is skipped, and the rest still goes")
    func brokenSymlinkIsSkipped() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let readable = try makeFile(
            in: scratch, named: "notes.txt", bytes: Data(repeating: 0x41, count: 12))
        // A dangling link stats like a file — its own path length is its size —
        // so nothing short of following it tells the two apart.
        _ = try makeSymlink(
            in: scratch, named: "broken",
            to: scratch.appendingPathComponent("nothing-\(UUID().uuidString)"))
        let broken = scratch.appendingPathComponent("broken")

        #expect(harness.service.startDrop(urls: [broken, readable]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let offer = try #require(harness.recorder.dropOffers.first)
        #expect(offer.repInfo.map(\.filename) == ["notes.txt"])
        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .itemsSkipped(note: harness.skippedNote()))
    }

    @Test("a file the user cannot open is skipped, and the rest still goes")
    func unopenableFileIsSkipped() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let readable = try makeFile(
            in: scratch, named: "notes.txt", bytes: Data(repeating: 0x41, count: 12))
        let locked = try makeFile(
            in: scratch, named: "noperm.bin", bytes: Data(repeating: 0x42, count: 34))
        try makeUnopenable(locked)

        #expect(harness.service.startDrop(urls: [locked, readable]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let offer = try #require(harness.recorder.dropOffers.first)
        #expect(offer.repInfo.map(\.filename) == ["notes.txt"])
        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .itemsSkipped(note: harness.skippedNote()))
    }

    @Test("a link that resolves is sent as its target's content under its own name")
    func symlinkSendsItsTargetsBytes() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let payload = Data("the target's bytes".utf8)
        let target = try makeFile(in: scratch, named: "target.txt", bytes: payload)
        let link = try makeSymlink(in: scratch, named: "shortcut.txt", to: target)

        #expect(harness.service.startDrop(urls: [link]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        let rep = try #require(harness.recorder.dropOffers.first?.repInfo.first)
        // The name the user dragged, carrying what it points at.
        #expect(rep.filename == "shortcut.txt")
        #expect(rep.byteCount == UInt64(payload.count))

        let xid = transferID(generation: 1, repIndex: 0)
        let received = try await harness.pull(generation: 1, transferID: xid, uti: rep.uti)
        let unpacked = try extractedClipboardArchive(received.payload)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(
            try Data(contentsOf: unpacked.appendingPathComponent("shortcut.txt")) == payload)
        #expect(harness.failure == nil)
    }

    /// One gesture is owed one sentence with one number (docs/CLIPBOARD.md §13):
    /// a skip announced when the offer goes out, ahead of the guest's own
    /// losses, is a second notice carrying a smaller count than the verdict
    /// behind it.
    @Test("a gather-time skip is announced once, in the drop's own verdict")
    func gatherTimeSkipIsAnnouncedInTheVerdict() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let readable = try makeFile(in: scratch, named: "notes.txt", bytes: Data("a".utf8))
        let missing = scratch.appendingPathComponent("gone-\(UUID().uuidString).bin")

        #expect(harness.service.startDrop(urls: [readable, missing]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        // The guest can still lose an item of its own, so nothing is said yet.
        #expect(harness.failure == nil)

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()

        #expect(harness.failure == .itemsSkipped(note: harness.skippedNote()))
        #expect(harness.reports.refusals.count == 1)
    }

    // MARK: - Reading the dropped items

    @Test("nothing about a dropped item is read on the main actor")
    func metadataIsReadOffTheMainActor() async throws {
        // The hop never runs, so anything the offer needs that this test can
        // still observe would have been read on the drag's own actor.
        let harness = try Harness(runOffMainActor: { _ in })
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))

        try await harness.recorder.expectNoNewFrames(sinceCount: 0, for: 0.2)
        #expect(harness.reports.latest == .idle)
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

    // MARK: - An item that stops being readable after the offer

    @Test("an item that can't be read when the guest asks fails only that item")
    func unreadableAtPullTimeIsSkippedNotFatal() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let locked = try makeFile(
            in: scratch, named: "locked.bin", bytes: Data(repeating: 0x42, count: 64))
        let payload = Data("still here".utf8)
        let readable = try makeFile(in: scratch, named: "notes.txt", bytes: payload)

        #expect(harness.service.startDrop(urls: [locked, readable]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let reps = try #require(harness.recorder.dropOffers.first?.repInfo)
        #expect(reps.map(\.filename) == ["locked.bin", "notes.txt"])

        // Both were readable when the drag was taken; one stops being so before
        // the guest gets to it.
        try makeUnopenable(locked)

        let first = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: reps[0].uti)
        #expect(first.abortCode == ClipboardStreamAbortCode.readError.rawValue)
        // The batch is not over: the guest asks for the next item and gets it.
        let second = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 1), uti: reps[1].uti)
        #expect(second.isComplete)
        let unpacked = try extractedClipboardArchive(second.payload)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("notes.txt")) == payload)

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()
        // What went missing is named, rather than the whole drop reading as lost.
        #expect(harness.failure == .itemsSkipped(note: harness.skippedNote()))
        let wording = try #require(harness.wording)
        #expect(wording.headline == "Some files not copied to \u{201C}Drop VM\u{201D}.")
        #expect(wording.menuLine == "Drop: some files weren't sent")
    }

    @Test("a drop whose every item became unreadable says nothing was sent")
    func everyItemUnreadableAtPullTimeSaysNothingWasSent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try makeFile(in: scratch, named: "one.bin", bytes: Data("one".utf8))
        let second = try makeFile(in: scratch, named: "two.bin", bytes: Data("two".utf8))

        #expect(harness.service.startDrop(urls: [first, second]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let reps = try #require(harness.recorder.dropOffers.first?.repInfo)

        try makeUnopenable(first)
        try makeUnopenable(second)
        for index in reps.indices {
            let received = try await harness.pull(
                generation: 1, transferID: transferID(generation: 1, repIndex: index),
                uti: reps[index].uti)
            #expect(received.abortCode == ClipboardStreamAbortCode.readError.rawValue)
        }

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.waitForFailure()
        // Nothing crossed, so "the rest were" sent would be a lie.
        #expect(harness.failure == .itemsUnreadable)
    }

    @Test("items lost before and after the offer are named as one count")
    func skipsAtBothStagesAreCountedTogether() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try makeSymlink(
            in: scratch, named: "broken",
            to: scratch.appendingPathComponent("nothing-\(UUID().uuidString)"))
        let broken = scratch.appendingPathComponent("broken")
        let locked = try makeFile(in: scratch, named: "locked.bin", bytes: Data("locked".utf8))
        let payload = Data("still here".utf8)
        let readable = try makeFile(in: scratch, named: "notes.txt", bytes: payload)

        #expect(harness.service.startDrop(urls: [broken, locked, readable]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let reps = try #require(harness.recorder.dropOffers.first?.repInfo)
        #expect(reps.map(\.filename) == ["locked.bin", "notes.txt"])

        try makeUnopenable(locked)
        let first = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: reps[0].uti)
        #expect(first.abortCode == ClipboardStreamAbortCode.readError.rawValue)
        let second = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 1), uti: reps[1].uti)
        #expect(second.isComplete)

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        // The verdict counts both stages, rather than restating whichever one
        // spoke last — and it is the only thing the user is interrupted with.
        try await harness.reports.wait {
            harness.failure == .itemsSkipped(note: harness.skippedNote(count: 2))
        }
        #expect(harness.reports.refusals.count == 1)
    }

    @Test("a drag loses every item across both stages and says nothing was sent")
    func losingEveryItemAcrossBothStagesSaysNothingWasSent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try makeSymlink(
            in: scratch, named: "broken",
            to: scratch.appendingPathComponent("nothing-\(UUID().uuidString)"))
        let broken = scratch.appendingPathComponent("broken")
        let locked = try makeFile(in: scratch, named: "locked.bin", bytes: Data("locked".utf8))

        #expect(harness.service.startDrop(urls: [broken, locked]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let reps = try #require(harness.recorder.dropOffers.first?.repInfo)

        try makeUnopenable(locked)
        let received = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: reps[0].uti)
        #expect(received.abortCode == ClipboardStreamAbortCode.readError.rawValue)

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        // The one item that was offered is the one that failed, so the drag as a
        // whole delivered nothing — "the rest were" sent has nothing to describe.
        try await harness.reports.wait { harness.failure == .itemsUnreadable }
    }

    @Test("a later drag losing an item raises its own refusal, not an echo of the last")
    func aRepeatedPartialLossIsAnnouncedAgain() async throws {
        // Further out than the run can reach, so every drop here ends inside its
        // reveal gate the way a drag of two small files does: announced as
        // queued, retired without ever opening a bar.
        let harness = try Harness(progressRevealDelay: 60)
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let first = try await dropLosingOneItem(harness, generation: 1, in: scratch)
        #expect(first.failure == .itemsSkipped(note: harness.skippedNote()))

        // A clean drag in between, which the guest serves to its end.
        let plain = try makeFile(in: scratch, named: "plain.txt", bytes: Data("plain".utf8))
        #expect(harness.service.startDrop(urls: [plain]))
        try await harness.recorder.waitForFrames { harness.recorder.dropOffers.count == 2 }
        let clean = try #require(harness.recorder.dropOffers.last?.repInfo)
        let served = try await harness.pull(
            generation: 2, transferID: transferID(generation: 2, repIndex: 0), uti: clean[0].uti)
        #expect(served.isComplete)
        try harness.guest.send(makeDropCompleteFrame(generation: 2, outcome: .completed))

        // A third drag loses an item exactly as the first did. Same sentence,
        // separate gesture over separate files — so it is owed its own message
        // rather than collapsed into the one still standing.
        let third = try await dropLosingOneItem(harness, generation: 3, in: scratch)
        #expect(third.failure == .itemsSkipped(note: harness.skippedNote()))
        #expect(third.date != first.date)
    }

    /// Runs one drag of a readable file beside one that turns unreadable between
    /// the offer and the guest's pull, returning the refusal it leaves standing.
    private func dropLosingOneItem(
        _ harness: Harness, generation: UInt64, in scratch: URL
    ) async throws -> ClipboardTransferFinish {
        let standing = harness.reports.finish
        let locked = try makeFile(
            in: scratch, named: "locked-\(generation).bin", bytes: Data("locked".utf8))
        let readable = try makeFile(
            in: scratch, named: "notes-\(generation).txt", bytes: Data("still here".utf8))

        #expect(harness.service.startDrop(urls: [locked, readable]))
        try await harness.recorder.waitForFrames {
            harness.recorder.dropOffers.count == Int(generation)
        }
        let reps = try #require(harness.recorder.dropOffers.last?.repInfo)

        // Readable when the drag was gathered and unopenable by the time the
        // guest asks: the shape a folder holding a mode-000 entry arrives in,
        // where only the pull finds out.
        try makeUnopenable(locked)
        let lost = try await harness.pull(
            generation: generation, transferID: transferID(generation: generation, repIndex: 0),
            uti: reps[0].uti)
        #expect(lost.abortCode == ClipboardStreamAbortCode.readError.rawValue)
        let sent = try await harness.pull(
            generation: generation, transferID: transferID(generation: generation, repIndex: 1),
            uti: reps[1].uti)
        #expect(sent.isComplete)

        try harness.guest.send(makeDropCompleteFrame(generation: generation, outcome: .completed))
        try await harness.reports.wait { harness.reports.finish?.date != standing?.date }
        return try #require(harness.reports.finish)
    }

    // MARK: - Several drops at once

    @Test("a second drop is counted on the readout of the one the guest is serving")
    func aSecondDropIsCountedBehindTheOneStreaming() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try makeFile(in: scratch, named: "a.txt", bytes: Data(repeating: 0x41, count: 8))
        let second = try makeFile(in: scratch, named: "b.txt", bytes: Data(repeating: 0x42, count: 8))

        // The guest serves drops one job at a time, so the second waits its turn
        // with nothing of its own in flight.
        #expect(harness.service.startDrop(urls: [first]))
        #expect(harness.service.startDrop(urls: [second]))
        try await harness.recorder.waitForFrames { harness.recorder.dropOffers.count == 2 }

        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }

        // One bar, and the batch behind it counted rather than invisible.
        let readout = try #require(harness.reports.runningSnapshot)
        #expect(readout.gesture == .drop)
        #expect(readout.pendingBehind == 1)
        #expect(ClipboardProgressFormat.summary(readout).contains("1 more transfer pending"))
    }

    // MARK: - Cancelling

    @Test("the Cancel on a drop's readout stops that drop")
    func cancelFromTheReadoutStopsTheDrop() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }

        // What the dropdown renders: a drop's readout carries a Cancel, and the
        // click reaches the operation that readout names.
        let readout = try #require(harness.reports.runningSnapshot)
        #expect(readout.gesture == .drop)
        #expect(readout.isCancellable)
        #expect(harness.reports.cancelShownTransfer())

        // The job is retired on the wire and the bar stops where the cancel left
        // it rather than reading as a failure.
        try await harness.recorder.waitForFrames { !harness.recorder.dropReleases.isEmpty }
        try await harness.reports.wait { harness.reports.runningSnapshot == nil }
        #expect(harness.failure == nil)
    }

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
        // The Cancel the user could have clicked, taken while it was still on
        // screen — the drop then finishes underneath it.
        let shown = try #require(harness.reports.shownOperationID)

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.wait { harness.reports.runningSnapshot == nil }

        #expect(!harness.reports.reporter.cancel(shown))
        #expect(!harness.reports.reporter.cancel(shown))

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

    // MARK: - A drop the guest never takes

    /// The unclaimed-drop deadlines the service has armed, fired by hand.
    ///
    /// Not `@MainActor`: the service arms these from the main actor while the
    /// test reads the tally, so the state is lock-guarded instead.
    private final class ManualDeadlines: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@MainActor @Sendable () -> Void] = []

        /// Fires whenever a deadline is armed.
        let armed = AsyncGate()

        /// How many armings are waiting to be fired.
        var count: Int { lock.withLock { pending.count } }

        /// Armings made over the whole run, which a wait can count on where the
        /// pending tally rises and falls as deadlines re-arm.
        var total: Int { lock.withLock { armedCount } }

        private var armedCount = 0

        /// The seam the service is built with.
        var schedule: @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void {
            { [self] _, work in
                lock.withLock {
                    pending.append(work)
                    armedCount += 1
                }
                armed.notify()
            }
        }

        /// Runs every armed deadline, whether or not it is still the live one.
        @MainActor
        func fireAll() {
            let due = lock.withLock {
                let due = pending
                pending.removeAll()
                return due
            }
            for work in due { work() }
        }
    }

    @Test("a drop the guest never asks for is called off, and says so")
    func unclaimedDropIsCalledOff() async throws {
        let deadlines = ManualDeadlines()
        let harness = try Harness(scheduleDropDeadline: deadlines.schedule)
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(
            in: scratch, named: "big.bin", bytes: Data(repeating: 0x43, count: 64))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try await deadlines.armed.wait { deadlines.count == 1 }
        deadlines.fireAll()

        // A drop's readout is closed by the guest's `DropComplete`, so without
        // this the gesture would report nothing at all, ever.
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .unclaimed)
        #expect(try #require(harness.wording).menuLine == "Drop: the VM never took the files")
        // The guest may be wedged rather than gone, so the offer is withdrawn.
        try await harness.recorder.waitForFrames { !harness.recorder.dropReleases.isEmpty }
    }

    @Test("a drop waiting behind one the guest is streaming is not called off")
    func queuedDropKeepsItsPlace() async throws {
        let deadlines = ManualDeadlines()
        let harness = try Harness(scheduleDropDeadline: deadlines.schedule)
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))
        let second = try makeFile(in: scratch, named: "b.txt", bytes: Data("b".utf8))

        #expect(harness.service.startDrop(urls: [first]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try await deadlines.armed.wait { deadlines.count == 1 }

        // The guest takes the first batch, which is what says it is working
        // rather than ignoring the host.
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)

        // The guest serves drops one job at a time, so this one waits its turn
        // with nothing of its own in flight — and no deadline of its own.
        #expect(harness.service.startDrop(urls: [second]))
        try await harness.recorder.waitForFrames { harness.recorder.dropOffers.count == 2 }
        // Every deadline armed by now belongs to the batch the guest is
        // serving, whose bytes moved during the window — so firing them calls
        // nothing off, and the queued batch is not among them.
        deadlines.fireAll()
        #expect(harness.failure == nil)

        // Once the first batch is over, the one behind it is owed an answer
        // again — and gets a deadline of its own.
        let armedSoFar = deadlines.total
        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await deadlines.armed.wait { deadlines.total > armedSoFar }
        deadlines.fireAll()
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .unclaimed)
    }

    @Test("a drop the guest began and then stopped moving is called off")
    func wedgedClaimedDropIsCalledOff() async throws {
        let deadlines = ManualDeadlines()
        let harness = try Harness(scheduleDropDeadline: deadlines.schedule)
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))

        #expect(harness.service.startDrop(urls: [file]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)

        // The clock on a claimed drop is an inactivity window: the bytes that
        // moved during this one start it again rather than ending the job.
        deadlines.fireAll()
        #expect(harness.failure == nil)

        // Nothing moves in the next one, and no `DropComplete` ever arrives —
        // the gesture would otherwise have no end at all.
        deadlines.fireAll()
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .timedOut)
        #expect(try #require(harness.wording).menuLine == "Drop: the VM stopped taking the files")
        try await harness.recorder.waitForFrames { !harness.recorder.dropReleases.isEmpty }
    }

    @Test("a batch queued behind a wedged drop still gets its own answer")
    func queuedDropOutlivesAWedgedOne() async throws {
        let deadlines = ManualDeadlines()
        let harness = try Harness(scheduleDropDeadline: deadlines.schedule)
        defer { harness.tearDown() }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try makeFile(in: scratch, named: "a.txt", bytes: Data("a".utf8))
        let second = try makeFile(in: scratch, named: "b.txt", bytes: Data("b".utf8))

        #expect(harness.service.startDrop(urls: [first]))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)
        #expect(harness.service.startDrop(urls: [second]))
        try await harness.recorder.waitForFrames { harness.recorder.dropOffers.count == 2 }

        // The guest holds the first batch open and never sends a verdict for
        // it. The batch behind it is owed an answer of its own, which nothing
        // would ever give it while the wedged one suppressed every deadline.
        deadlines.fireAll()
        deadlines.fireAll()
        try await harness.reports.waitForFailure()
        #expect(harness.failure == .timedOut)

        // Calling the wedged one off is what puts the batch behind it back on
        // a clock of its own.
        deadlines.fireAll()
        try await harness.reports.wait { harness.failure == .unclaimed }
    }

    // MARK: - Staged promise files

    /// A directory standing in for the one a promise drag writes into, holding
    /// the single file the drop then offers.
    private func makeStagedDrop() throws -> (directory: URL, file: URL) {
        let directory = try makeScratchDirectory()
        return (directory, try makeFile(in: directory, named: "promised.png", bytes: Data("p".utf8)))
    }

    private func isStaged(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    @Test("the guest's verdict frees the directory a promise drag staged")
    func completedDropReleasesItsStagedFiles() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let staged = try makeStagedDrop()
        defer { DropPromiseStaging.release(staged.directory) }

        #expect(harness.service.startDrop(urls: [staged.file], stagedIn: staged.directory))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }
        // The guest pulls long after the drag is over, so the files stand until
        // it says what became of them.
        #expect(isStaged(staged.directory))

        try harness.guest.send(makeDropCompleteFrame(generation: 1, outcome: .completed))
        try await harness.reports.wait { harness.reports.runningSnapshot == nil }

        #expect(!isStaged(staged.directory))
    }

    @Test("a drop the guest never takes frees what it staged")
    func unclaimedDropReleasesItsStagedFiles() async throws {
        let deadlines = ManualDeadlines()
        let harness = try Harness(scheduleDropDeadline: deadlines.schedule)
        defer { harness.tearDown() }
        let staged = try makeStagedDrop()
        defer { DropPromiseStaging.release(staged.directory) }

        #expect(harness.service.startDrop(urls: [staged.file], stagedIn: staged.directory))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        try await deadlines.armed.wait { deadlines.count == 1 }
        deadlines.fireAll()

        try await harness.reports.waitForFailure()
        #expect(harness.failure == .unclaimed)
        #expect(!isStaged(staged.directory))
    }

    @Test("a cancelled drop frees what it staged")
    func cancelledDropReleasesItsStagedFiles() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let staged = try makeStagedDrop()
        defer { DropPromiseStaging.release(staged.directory) }

        #expect(harness.service.startDrop(urls: [staged.file], stagedIn: staged.directory))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }
        let uti = try #require(harness.recorder.dropOffers.first?.repInfo.first?.uti)
        let served = try await harness.pull(
            generation: 1, transferID: transferID(generation: 1, repIndex: 0), uti: uti)
        #expect(served.isComplete)
        try await harness.reports.wait { harness.reports.runningSnapshot != nil }
        #expect(harness.reports.cancelShownTransfer())

        try await harness.recorder.waitForFrames { !harness.recorder.dropReleases.isEmpty }
        #expect(!isStaged(staged.directory))
    }

    @Test("the channel going frees what a drop still in flight staged")
    func interruptedDropReleasesItsStagedFiles() async throws {
        let harness = try Harness()
        let staged = try makeStagedDrop()
        defer { DropPromiseStaging.release(staged.directory) }

        #expect(harness.service.startDrop(urls: [staged.file], stagedIn: staged.directory))
        try await harness.recorder.waitForFrames { !harness.recorder.dropOffers.isEmpty }

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        try await harness.reports.waitForFailure()
        #expect(!isStaged(staged.directory))
    }

    @Test("a drop the service refuses leaves its staged files to the caller")
    func refusedDropLeavesStagedFilesAlone() throws {
        let harness = try Harness()
        let staged = try makeStagedDrop()
        defer { DropPromiseStaging.release(staged.directory) }

        harness.recorder.cancel()
        harness.service.stop()
        harness.guest.close()

        // The drop was never taken on, so the caller still holds the only
        // reference to what it staged.
        #expect(!harness.service.startDrop(urls: [staged.file], stagedIn: staged.directory))
        #expect(isStaged(staged.directory))
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
        #expect(harness.reports.cancelShownTransfer())
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
