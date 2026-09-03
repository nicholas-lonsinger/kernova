import Testing
import Foundation
import AppKit
import Darwin
import KernovaKit
import KernovaTestSupport
import UniformTypeIdentifiers

// MARK: - Fake Pasteboard

/// In-memory `Pasteboard` over `KernovaTestSupport`'s ``FakeWritePasteboard``.
///
/// The write half — promise registration, the OS-fires-a-provider seam, the
/// write-failure seam — is the shared double both ends of the wire use. Added
/// here: the read half `Pasteboard` composes with it, and the test-only
/// resident setup (`setItem`/`setItems`/`setString`) that models a *user*
/// copying inside the guest, which the agent's outbound poll reads. A promise
/// write leaves no resident bytes; a fired provider's bytes are what its item
/// serves from afterwards, as a real `NSPasteboardItem` retains them.
///
/// Thread-safe: ``invokeProvider(forType:itemIndex:)`` blocks its calling thread
/// until the lazy pull behind the promise resolves, so it runs off the test's
/// main actor.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let writer = FakeWritePasteboard()
    private let lock = NSLock()
    /// Resident items — a user's own copy, one entry per pasteboard item.
    private var residents: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
    /// Bytes a fired provider resolved, which a promised item serves from.
    private var resolved: [NSPasteboard.PasteboardType: Data] = [:]

    /// Fires after every mutation; await it instead of polling.
    var changed: AsyncGate { writer.changed }

    var changeCount: Int { writer.changeCount }

    /// The pasteboard's items: a standing promise's, which serve only what a
    /// fired provider has already resolved, or the user's own copy.
    var items: [any ClipboardPasteboardItemReading] {
        let promised = writer.promisedTypesByItem
        guard promised.isEmpty else {
            let bytes = lock.withLock { resolved }
            return promised.map { FakePasteboardItem(types: $0, bytes: bytes) }
        }
        return lock.withLock { residents }.map(FakePasteboardItem.init)
    }

    // MARK: - Promised writes

    /// Every promised type across all items, concatenated in item order (a
    /// multi-file offer promises one item per file).
    var promisedTypesForTesting: [NSPasteboard.PasteboardType] { writer.promisedTypes }

    /// Number of promised pasteboard items the agent's last write registered.
    var promisedItemCountForTesting: Int { writer.promisedItemCount }

    /// Options passed to the most recent `prepareForNewContents(with:)`; `nil`
    /// until the agent's first promise write.
    var lastPrepareOptionsForTesting: NSPasteboard.ContentsOptions? { writer.lastPrepareOptions }

    /// How many promised providers have been fired, for a test proving the
    /// agent's own poll fired none.
    var providerInvocationCountForTesting: Int { writer.providerInvocations }

    /// Makes the next `times` `writeItems(_:)` calls fail, modelling an
    /// OS-level pasteboard write failure.
    func failNextWrite(times: Int = 1) { writer.failNextWrite(times: times) }

    /// Fires a promised item's provider the way the OS does, synchronously.
    ///
    /// `itemIndex` targets one item, needed when several promise the same type
    /// (`.fileURL` across a multi-file offer); `nil` takes the first offering
    /// it. **This blocks until the pull behind the promise resolves**, so call
    /// it off the test's main actor.
    func invokeProvider(
        forType type: NSPasteboard.PasteboardType, itemIndex: Int? = nil
    ) -> Data? {
        guard let bytes = writer.invokeProvider(forType: type, itemIndex: itemIndex) else {
            return nil
        }
        lock.withLock { resolved[type] = bytes }
        return bytes
    }

    @discardableResult
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        clearResidents()
        return writer.prepareForNewContents(with: options)
    }

    /// Registers one lazy promise per item, recording no bytes.
    @discardableResult
    func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let written = writer.writeItems(items)
        if written { clearResidents() }
        return written
    }

    @discardableResult
    func clearContents() -> Int {
        clearResidents()
        return writer.clearContents()
    }

    // MARK: - Test-only resident setup (a user copying inside the guest)

    /// Places resident (type, data) pairs, modelling a user copying in the
    /// guest. Clears any promise.
    @discardableResult
    func setItem(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        setItems([representations])
    }

    /// Places several resident pasteboard items, modelling a multi-select copy
    /// in the guest.
    @discardableResult
    func setItems(_ items: [[(type: NSPasteboard.PasteboardType, data: Data)]]) -> Bool {
        lock.withLock {
            residents = items
            resolved.removeAll()
        }
        // Drops any promise and bumps the change count, as a real write does.
        writer.clearContents()
        return true
    }

    /// Replaces the resident item with a single text representation —
    /// equivalent to a user copying text inside the guest.
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        setItem([(type: type, data: Data(string.utf8))])
    }

    private func clearResidents() {
        lock.withLock {
            residents.removeAll()
            resolved.removeAll()
        }
    }
}

// MARK: - Test Suite

@Suite("VsockGuestClipboardAgent state machine", .admissionGated)
struct VsockGuestClipboardAgentTests {
    // RATIONALE: every `…ForTesting` lifecycle poll in this suite is the
    // sanctioned no-signal kind (docs/TESTING.md "Async waits in tests") —
    // `liveChannelForTesting` and `inboundPromiseGenerationForTesting` read
    // main-queue-confined SUT internals that are neither `@Observable` nor
    // owned by a test double, and the agent publishes no transition a test
    // could arm on. Pasteboard-write waits use `pasteboard.changed` instead,
    // and the one filesystem-appearance poll names itself at its call site.

    // MARK: - Agent factory helpers

    /// Sets up an agent with the given pasteboard and a socket provider that
    /// returns the given fd on first call, transient failure thereafter.
    ///
    /// The short retry interval keeps the pause/resume wake-up snappy — the agent
    /// is now default-paused at construction, and `applyPolicy(enabled: true, …)` only
    /// takes effect on the next loop iteration after the current sleep.
    ///
    /// `dialled` collects the peer end of every data connection the agent opens,
    /// standing in for the host's data listener: a guest only ever dials, so
    /// every transfer in either direction arrives there. A test that drives one
    /// passes its own collector and closes it on teardown.
    private func makeAgent(
        pasteboard: FakePasteboard, agentFd: Int32,
        dialled: DialledDataConnections = DialledDataConnections(),
        clock: any EngineClock = MonotonicEngineClock(),
        stagingTempRoot: URL? = nil,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        reporter: ClipboardTransferReporter = ClipboardTransferReporter(),
        onClipboardNotice: @escaping @Sendable () -> Void = {}
    ) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard,
            label: "clipboard-test",
            clock: MonotonicEngineClock(),
            retryInterval: 0.05
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        let agent = VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, clock: clock,
            freeSpaceProvider: freeSpaceProvider,
            stagingTempRoot: stagingTempRoot
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString, isDirectory: true),
            reporter: reporter,
            progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap,
            dataDialer: dialled.dialer,
            onClipboardNotice: onClipboardNotice)
        return agent
    }

    /// Starts the agent, enables it (production agents are default-disabled
    /// until host policy says otherwise), and waits until `liveChannel` is
    /// published on the main queue.
    ///
    /// After this returns, callers driving
    /// `checkClipboardChange()` see a non-nil channel.
    private func startAgentAndWaitForLiveChannel(
        agent: VsockGuestClipboardAgent,
        maxPasteBytes: Int = ClipboardPasteLimit.defaultBytes
    ) async throws {
        agent.start()
        agent.applyPolicy(enabled: true, maxPasteBytes: maxPasteBytes)
        try await waitUntil { agent.liveChannelForTesting != nil }
    }

    // MARK: - Outbound (agent is the sender)

    @Test("outbound text: a local change is announced as a metadata offer, then streamed on request")
    func outboundTextOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let text = "hello from guest"
        pasteboard.setString(text, forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        // The offer is metadata only: one inline text rep, no bytes.
        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        #expect(offer.generation >= 1)
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        #expect(info.uti == ClipboardContent.utf8TextUTI)
        #expect(info.isInline)
        #expect(info.byteCount == UInt64(Data(text.utf8).count))
        #expect(info.filename.isEmpty)

        // Pull rep 0: choose a transferID whose low 16 bits select the rep index.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        // The agent answers by dialling the transfer's own connection: reply,
        // payload, trailer.
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: dialled)
        #expect(transfer.reply.isInline)
        #expect(!transfer.reply.isArchive)
        #expect(transfer.payload == Data(text.utf8))
        #expect(transfer.reply.totalBytes == UInt64(Data(text.utf8).count))
        // The trailer's digest covers exactly the payload that arrived.
        #expect(transfer.isComplete)
    }

    @Test("outbound copied file: offered by stat (no read), streamed from disk on request")
    func outboundCopiedFileOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A non-image file, comfortably larger than the old 100 MiB cap would
        // have been *modeled* by — we keep the real bytes modest for speed and
        // assert the no-cap behavior by the rep simply being offered and
        // streamed in full. A copied file leaves only a file URL on the
        // pasteboard (Finder ⌘C).
        let contents = Data((0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let url = try writeTempFile(name: "notes.bin", data: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        // A large file is offered whole: the offer carries the stat'd size and
        // the real filename.
        #expect(info.byteCount == UInt64(contents.count))
        #expect(info.filename == "notes.bin")
        // A non-image file is file-only (not inlined) per shouldInline's rule.
        #expect(!info.isInline)

        // Request rep 0; the agent streams the file's bytes from disk.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))

        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: dialled)
        #expect(!transfer.reply.isInline)
        // The file crosses as a one-entry archive, so its wire size is unknown
        // when the reply goes out and the trailer carries the digest that proves
        // the payload arrived whole.
        #expect(transfer.reply.isArchive)
        #expect(transfer.reply.totalBytes == 0)
        #expect(transfer.isComplete)
        let unpacked = try extractedClipboardArchive(transfer.payload)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        // Nothing on a data connection repeats the offer's filename, so the name
        // the transfer delivers is the archive entry's.
        #expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["notes.bin"])
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("notes.bin")) == contents)
    }

    @Test("outbound copied zero-byte file: offered and streamed as an empty payload")
    func outboundCopiedZeroByteFileOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Finder copies an empty file, so the guest offers one: the stat gate
        // keeps the rep at `byteCount == 0` rather than dropping it.
        let url = try writeTempFile(name: "empty.bin", data: Data())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([(type: .fileURL, data: Data(url.absoluteString.utf8))])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let info = try #require(offer.repInfo.first)
        #expect(offer.repInfo.count == 1)
        #expect(info.byteCount == 0)
        #expect(info.filename == "empty.bin")
        #expect(!info.isInline)

        // The whole stream path survives at zero bytes: the archive of an
        // empty entry still crosses and unpacks to an empty file.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))

        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: dialled)
        #expect(transfer.reply.totalBytes == 0)
        #expect(transfer.reply.isArchive)
        #expect(transfer.isComplete)
        let unpacked = try extractedClipboardArchive(transfer.payload)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        // The offer's filename is not repeated on the connection; the entry the
        // archive delivers carries it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["empty.bin"])
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("empty.bin")).isEmpty)
    }

    @Test("serving a host pull publishes an outbound readout, cleared at the terminal")
    func outboundPullPublishesProgress() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Reveal instantly and dwell not at all, so one in-flight transfer both
        // surfaces and clears inside the test — the reports the app delegate
        // hands to `AgentStatusItemController.transferReportChanged`.
        let reports = await MainActor.run { ClipboardTransferReports() }
        let reporter = await MainActor.run { reports.reporter }
        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, dialled: dialled,
            progressRevealDelay: 0, progressIdleGap: 0, reporter: reporter)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let contents = Data((0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let url = try writeTempFile(name: "notes.bin", data: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([(type: .fileURL, data: Data(url.absoluteString.utf8))])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let info = try #require(offer.repInfo.first)

        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: dialled)
        let unpacked = try extractedClipboardArchive(transfer.payload)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("notes.bin")) == contents)

        try await reports.wait { !reports.finalSnapshots.isEmpty && reports.runningSnapshot == nil }
        let readout = try #require(await MainActor.run { reports.finalSnapshots.last })
        #expect(readout.direction == .outbound)
        #expect(readout.peerName == "Mac")
        #expect(readout.currentItemName == "notes.bin")
        #expect(readout.totalBytes == UInt64(contents.count))
        // The terminal credits the transfer in full, so the last readout before
        // the clear reads as complete rather than stopping short.
        #expect(readout.bytesTransferred == UInt64(contents.count))
        // The Mac's user is the one pasting, so this side's readout is serving
        // their paste — which is what may open the dropdown in this guest.
        #expect(readout.gesture == .peerPaste)
    }

    @Test("a copied image file is offered inline with the image UTI")
    func outboundCopiedImageFileOffersInline() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let url = try writeTempFile(name: "picture.png", data: png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let info = try #require(offer.repInfo.first)
        #expect(info.uti == UTType.png.identifier)
        #expect(info.filename == "picture.png")
        // An image file is inlined (per shouldInline) so a paste yields the image.
        #expect(info.isInline)
        #expect(info.byteCount == UInt64(png.count))

        // The streamed bytes are the file's bytes (read from disk on request).
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: dialled)
        #expect(transfer.payload == png)
    }

    @Test("outbound multiple files: every copied file is offered as its own rep, in order")
    func outboundMultipleFiles() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let a = try writeTempFile(name: "a.txt", data: Data("aaa".utf8))
        let b = try writeTempFile(name: "b.bin", data: Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        // A multi-select Finder ⌘C leaves one file URL per pasteboard item.
        pasteboard.setItems([
            [(type: .fileURL, data: Data(a.absoluteString.utf8))],
            [(type: .fileURL, data: Data(b.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.count == 2)
        #expect(offer.repInfo.map(\.filename) == ["a.txt", "b.bin"])
        // Both are non-image files → file-only.
        #expect(offer.repInfo.allSatisfy { !$0.isInline })
        #expect(offer.repInfo[1].byteCount == 4)
    }

    @Test("outbound: a staging-root file among several copied files is dropped, the rest offered")
    func outboundDropsStagedFileAmongSeveral() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Materialize a file into the agent's staging root via an inbound paste.
        let contents = Data("staged body".utf8)
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 3,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "notes.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }
        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await serveInboundTransfer(
            on: dialled, generation: 3, filename: "notes.txt", payload: contents, isInline: false)
        let staged = try #require(
            (await pull.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))

        // Copy [the staged file, a fresh file]: the staging-root file is dropped
        // per-file; only the fresh file is offered back to the host.
        let fresh = try writeTempFile(name: "fresh.txt", data: Data("fresh".utf8))
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        pasteboard.setItems([
            [(type: .fileURL, data: Data(staged.absoluteString.utf8))],
            [(type: .fileURL, data: Data(fresh.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.map(\.filename) == ["fresh.txt"])
    }

    // MARK: - Folders

    @Test(
        "outbound copied folder: offered on a stat-walk estimate, streamed as an archive with no total"
    )
    func outboundCopiedFolderOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agentStagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: agentStagingRoot) }
        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, dialled: dialled,
            stagingTempRoot: agentStagingRoot)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A copied folder leaves one file URL on the pasteboard (Finder ⌘C).
        let folder = try writeTempFolder(
            name: "Project",
            files: [("README.md", Data("readme".utf8)), ("sub/n.txt", Data("nested".utf8))])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        pasteboard.setItem([(type: .fileURL, data: Data(folder.absoluteString.utf8))])
        await MainActor.run { agent.checkClipboardChange() }

        // The estimate walk runs off-main; the offer arrives once it lands. Its
        // `byte_count` is the stat-walk sum of the file sizes (6 + 6) — not an
        // archive size, because no archive exists at offer time.
        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        #expect(info.isDirectory)
        #expect(info.uti == UTType.folder.identifier)
        #expect(info.filename == "Project")
        #expect(!info.isInline)
        #expect(info.byteCount == 12)

        // Pull the rep: the agent archives at request time and the streamed
        // bytes are an `.aar` that extracts back to the tree.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: dialled)
        #expect(!transfer.reply.isInline)
        #expect(transfer.reply.isArchive)
        // The tree is compressed straight onto the wire, so its size is unknown
        // when the reply goes out; the trailer's digest is what proves the whole
        // archive arrived.
        #expect(transfer.reply.totalBytes == 0)
        #expect(transfer.isComplete)
        // The tree was compressed onto the wire, so nothing was staged to send it.
        #expect(materializedFiles(under: agentStagingRoot).isEmpty)

        let dest = try extractedClipboardArchive(transfer.payload)
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        #expect(
            try String(contentsOf: dest.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
        #expect(
            try String(contentsOf: dest.appendingPathComponent("sub/n.txt"), encoding: .utf8)
                == "nested")
    }

    @Test("a host offer landing during a copied folder's estimate walk is not read back as a copy")
    func hostOfferDuringFolderWalkIsNotReadBackAsACopy() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let folder = try writeTempFolder(name: "Walked", files: [("a.txt", Data("a".utf8))])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let walked = AsyncGate()
        let walks = Box(0)
        await MainActor.run {
            agent.onFileResolveCompletedForTesting = {
                walks.value += 1
                walked.notify()
            }
        }
        pasteboard.setItem([(type: .fileURL, data: Data(folder.absoluteString.utf8))])

        // The poll starts the folder's off-main walk; on the same main-queue
        // turn a host offer lands and the agent's own promise replaces the
        // folder on the pasteboard — so the walk's completion, which hops back
        // to main, necessarily runs after that write.
        await MainActor.run {
            agent.checkClipboardChange()
            agent.handleControlFrameForTesting(makeTextOfferFrame(generation: 31, text: "from host"))
        }
        try await walked.wait { walks.value == 1 }
        #expect(pasteboard.promisedTypesForTesting.contains(.string))

        // The next poll finds nothing new: the promise this agent wrote is not
        // read back as a copy — nothing offered, no copy blamed for coming up
        // empty, the menu still on the host's offer.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
        let activity = await MainActor.run { agent.clipboardActivity }
        #expect(activity == .offeredFromHost)
        #expect(pasteboard.promisedTypesForTesting.contains(.string))
    }

    @Test(
        "outbound: a folder carrying no file bytes is offered at 0 bytes and still streams its tree"
    )
    func outboundByteFreeFolderOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Two copied folders a stat walk sizes at 0: one empty, one holding only
        // a subdirectory and a zero-byte file.
        let empty = try writeTempFolder(name: "Empty", files: [])
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        let scaffold = try writeTempFolder(name: "Scaffold", files: [("sub/.keep", Data())])
        defer { try? FileManager.default.removeItem(at: scaffold.deletingLastPathComponent()) }
        pasteboard.setItems([
            [(type: .fileURL, data: Data(empty.absoluteString.utf8))],
            [(type: .fileURL, data: Data(scaffold.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.map(\.filename) == ["Empty", "Scaffold"])
        #expect(offer.repInfo.map(\.isDirectory) == [true, true])
        #expect(offer.repInfo.map(\.byteCount) == [0, 0])

        // The zero estimate gates nothing: each rep streams its tree on request
        // and the arriving archive bytes rebuild it. Which rep each transfer
        // carries is its id — nothing on the connection repeats the offer's
        // filename — so the trees themselves are what tell the two apart.
        let emptyTransfer = try await requestOutboundRep(
            offer: offer, repIndex: 0, from: hostChannel, dialled: dialled)
        let emptyOut = try extractedClipboardArchive(emptyTransfer.payload)
        defer { try? FileManager.default.removeItem(at: emptyOut.deletingLastPathComponent()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyOut.path).isEmpty)

        let scaffoldTransfer = try await requestOutboundRep(
            offer: offer, repIndex: 1, from: hostChannel, dialled: dialled)
        let scaffoldOut = try extractedClipboardArchive(scaffoldTransfer.payload)
        defer { try? FileManager.default.removeItem(at: scaffoldOut.deletingLastPathComponent()) }
        #expect(
            FileManager.default.fileExists(
                atPath: scaffoldOut.appendingPathComponent("sub/.keep").path))
    }

    @Test("outbound: a copy nothing survives releases the host's previous offer")
    func outboundUnreadableCopyReleasesThePreviousOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let offer = try await awaitOffer(on: hostChannel)

        // A copied item whose resource values can't be read yields no file
        // candidate, and the raw file-url flavor it leaves behind is filtered
        // before reading — so this copy has nothing to offer at all.
        pasteboard.setItem([
            (type: .fileURL, data: Data("file:///nonexistent/\(UUID().uuidString)".utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let release = try await awaitRelease(on: hostChannel)
        #expect(release.generation == offer.generation)

        // The release emptied the Mac's clipboard, so re-copying what it was
        // holding is a copy that has to reach it — the send-dedup latch that said
        // the host already had it stopped being true at the release.
        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let reoffer = try await awaitOffer(on: hostChannel)
        #expect(reoffer.repInfo.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(reoffer.generation > offer.generation)
    }

    @Test("outbound: a copy nothing survives tells the guest's own menu it didn't cross, once")
    func outboundUnreadableCopyRaisesTheGuestNotice() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        _ = try await awaitOffer(on: hostChannel)
        #expect(await MainActor.run { agent.clipboardActivity } == .offeredToHost)

        pasteboard.setItem([
            (type: .fileURL, data: Data("file:///nonexistent/\(UUID().uuidString)".utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        // The release emptied the Mac's clipboard, so leaving the line at the
        // copy that crossed before it would read as the copy that just didn't.
        try await notices.changed.wait { notices.value == 1 }
        #expect(await MainActor.run { agent.clipboardActivity } == .copyCarriedNothing)

        // A re-check of the same snapshot is not a second copy, so it is not
        // owed a second interruption.
        await MainActor.run { agent.checkClipboardChange() }
        #expect(notices.value == 1)
    }

    @Test("outbound: a copied file deleted since carries nothing — its path never crosses as text")
    func outboundVanishedFileNeverOffersItsPath() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A copy this connection watched arrive, so the one after it reads as a
        // gesture the guest made rather than a standing snapshot re-evaluated.
        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let offer = try await awaitOffer(on: hostChannel)

        // A Finder ⌘C leaves the file's URL beside its path as text; the file is
        // deleted, renamed or unmounted before the poll reads the snapshot.
        let gone = try writeTempFile(name: "gone.txt", data: Data("bye".utf8))
        defer { try? FileManager.default.removeItem(at: gone.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: gone)
        pasteboard.setItem([
            (type: .fileURL, data: Data(gone.absoluteString.utf8)),
            (type: .string, data: Data(gone.path.utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        // The path text is the file's descriptor, not what the user copied, so
        // the copy is a total loss: the host's offer is withdrawn and the
        // guest's own menu is what accounts for it.
        let release = try await awaitRelease(on: hostChannel)
        #expect(release.generation == offer.generation)
        try await notices.changed.wait { notices.value == 1 }
        #expect(await MainActor.run { agent.clipboardActivity } == .copyCarriedNothing)
        try await expectNoOffer(from: hostChannel)
    }

    @Test("outbound: a copy whose second file can't be read offers the first and names the loss")
    func outboundPartlyReadableCopyNamesWhatItLeftOut() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let readable = try writeTempFile(name: "readable.txt", data: Data("body".utf8))
        defer { try? FileManager.default.removeItem(at: readable.deletingLastPathComponent()) }
        // A mode-000 file stats exactly like a readable one, so only asking for
        // the open permission separates them.
        let sealed = try writeTempFile(name: "sealed.txt", data: Data("secret".utf8))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: sealed.path)
            try? FileManager.default.removeItem(at: sealed.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sealed.path)

        pasteboard.setItems([
            [(type: .fileURL, data: Data(readable.absoluteString.utf8))],
            [(type: .fileURL, data: Data(sealed.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.map(\.filename) == ["readable.txt"])

        // The host's readout covers what the offer carried, so the item it left
        // out is named here or nowhere (docs/CLIPBOARD.md §13).
        try await notices.changed.wait { notices.value == 1 }
        #expect(
            await MainActor.run { agent.clipboardActivity } == .copyPartlyCarried(skipped: 1))
    }

    @Test("outbound: the first poll of a connection re-reads a snapshot without blaming a copy")
    func outboundFirstPollAfterConnectingReportsNoCopy() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        // A snapshot already standing when the channel comes up, whose flavors
        // read as nothing. The promise this agent wrote for a host offer is the
        // one that matters: reconnecting drops the promise behind it, so its
        // providers stop serving and every type comes back empty — for a copy
        // the guest user never made.
        pasteboard.setItem([
            (type: .fileURL, data: Data("file:///nonexistent/\(UUID().uuidString)".utf8))
        ])
        try await startAgentAndWaitForLiveChannel(agent: agent)
        await MainActor.run { agent.checkClipboardChange() }

        // Re-announcing to a host that has no record of prior offers is not a
        // gesture anyone just made, so it interrupts nobody and leaves the line
        // where policy set it.
        #expect(notices.value == 0)
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)

        // The copy after it is watched arriving, so that one is reported.
        pasteboard.setItem([
            (type: .fileURL, data: Data("file:///nonexistent/\(UUID().uuidString)".utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }
        try await notices.changed.wait { notices.value == 1 }
        #expect(await MainActor.run { agent.clipboardActivity } == .copyCarriedNothing)
    }

    @Test("outbound: an emptied clipboard withdraws the offer without reading as a failed copy")
    func outboundEmptiedPasteboardReturnsTheMenuToEnabled() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let offer = try await awaitOffer(on: hostChannel)

        pasteboard.clearContents()
        await MainActor.run { agent.checkClipboardChange() }

        let release = try await awaitRelease(on: hostChannel)
        #expect(release.generation == offer.generation)

        // Emptying the clipboard is nobody's failed gesture: the offer it had
        // crossed under is gone, which is all the line may still claim, and
        // there is no outcome worth opening the dropdown over.
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)
        #expect(notices.value == 0)
    }

    @Test("outbound suppressed: a transient snapshot is not a copy, so it releases nothing")
    func outboundSuppressedSnapshotLeavesTheOfferStanding() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("carried", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        _ = try await awaitOffer(on: hostChannel)

        // The source app restores the pasteboard within seconds and clipboard
        // managers ignore the marker by convention, so the clipboard before it is
        // the one that still stands — on the host as much as in the guest.
        pasteboard.setItem([
            (
                type: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                data: Data([1])
            ),
            (type: .string, data: Data("noise".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let extra = try await maybeNextFrame(from: hostChannel)
        #expect(extra == nil)
    }

    /// Requests representation `repIndex` of `offer` and reads the transfer the
    /// agent dials to answer it.
    private func requestOutboundRep(
        offer: Kernova_V1_ClipboardOffer, repIndex: UInt64, from channel: VsockChannel,
        dialled: DialledDataConnections
    ) async throws -> ReceivedTransfer {
        let transferID = (offer.generation << 16) | repIndex
        try channel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID,
                uti: offer.repInfo[Int(repIndex)].uti))
        return try await collectOutboundTransfer(transferID: transferID, from: dialled)
    }

    @Test("inbound directory stream with a digest mismatch delivers nothing — no folder appears")
    func inboundDirectoryDigestMismatchFails() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A valid archive whose stream will nonetheless end with a wrong digest.
        let src = try writeTempFolder(name: "Broken", files: [("f.txt", Data("x".utf8))])
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let aarBytes = try clipboardArchiveBytes(ofDirectoryAt: src)

        try hostChannel.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: UInt64(aarBytes.count),
                        filename: "Broken", isInline: false, isDirectory: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        let connection = try await acceptPull(on: dialled, generation: 9)
        // The whole archive crosses, but the trailer carries the digest of
        // DIFFERENT bytes — the receiver must refuse to commit, so the pull
        // serves nothing and no folder materializes.
        let served = await offCooperativePool {
            defer { ClipboardDataConnection.end(fd: connection.fd) }
            do {
                try ClipboardDataConnection.writeFrame(
                    makeTransferReplyFrame(
                        transferID: connection.request.transferID, isArchive: true,
                        isInline: false, totalBytes: 0),
                    fd: connection.fd)
                try writeTransferBytes(fd: connection.fd, aarBytes)
                try ClipboardDataConnection.writeTrailer(
                    ClipboardTransferTrailer(
                        ending: .complete(digest: sha256(Data("not the archive".utf8)))),
                    fd: connection.fd)
                return true
            } catch {
                return false
            }
        }
        #expect(served)
        #expect(await pull.value == nil)
    }

    @Test("an empty/filtered pasteboard sends no offer")
    func filteredTypesProduceNoOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), data: Data([1]))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        try await expectNoOffer(from: hostChannel)
    }

    @Test(
        "outbound suppressed: a transient or auto-generated snapshot is not offered even with content",
        arguments: ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"])
    func outboundSuppressedSnapshot(marker: String) async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A real password/expansion item carries the marker alongside content;
        // the whole snapshot must be suppressed, not just the marker rep.
        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType(marker), data: Data([1])),
            (type: .string, data: Data("noise".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        try await expectNoOffer(from: hostChannel)
    }

    @Test("outbound concealed: a password snapshot is offered with isConcealed set")
    func outboundConcealedOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), data: Data([1])),
            (type: .string, data: Data("hunter2".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(offer.isConcealed)
        // The content still crosses — only the marker rep is dropped, so the
        // password can still be pasted on the host.
        #expect(offer.repInfo.map(\.uti) == [NSPasteboard.PasteboardType.string.rawValue])
    }

    @Test("snapshot offers UTIs in pasteboard order")
    func snapshotOffersUTIsInOrder() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("public.rtf"), data: Data("{rtf}".utf8)),
            (type: .string, data: Data("plain".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(
            offer.repInfo.map(\.uti) == ["public.rtf", NSPasteboard.PasteboardType.string.rawValue])
        #expect(offer.repInfo.allSatisfy { $0.isInline })
    }

    // MARK: - Echo suppression

    @Test("a registered host promise is not re-offered on the next poll (echo suppression)")
    func echoSuppression() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host offers text → agent registers a lazy promise (no pull, so no data
        // connection). The post-write changeCount is captured so the poll can't
        // self-trigger.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "from host"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }
        try await expectNoPull(on: dialled)

        // A poll right after the promise is registered must not re-offer it.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    @Test("a file materialized into the staging root is not offered back (staging-path guard)")
    func stagedFileNotReOffered() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host offers a non-image file rep; a `.fileURL` paste materializes it
        // under the agent's staging root and resolves to that local file URL.
        let contents = Data("staged file body".utf8)
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 3,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "notes.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await serveInboundTransfer(
            on: dialled, generation: 3, filename: "notes.txt", payload: contents, isInline: false)
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(FileManager.default.fileExists(atPath: staged.path))

        // A poll now sees a .fileURL pointing inside the staging root; the
        // staging-path guard must skip it so it isn't offered back to the host.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    // MARK: - Inbound (agent is the receiver, lazy promise model)

    @Test("inbound text offer registers a promise and pulls nothing until the OS asks")
    func inboundTextOfferRegistersPromise() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host announces one inline text rep. The agent registers a lazy promise
        // for the text UTI and pulls NOTHING — no data connection is opened.
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "clipboard payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }
        try await expectNoPull(on: dialled)

        // The promise write is scoped `.currentHostOnly` so the guest's
        // continuity-pasteboard advertiser can't fetch the promised flavors at
        // offer time (#542) — an unscoped write would let the OS pull the full
        // payload with zero user interaction on the sync path.
        #expect(pasteboard.lastPrepareOptionsForTesting == .currentHostOnly)

        // The promise generation is recorded; a poll afterward does not re-offer.
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == 42)
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    @Test("disable and stop keep materialized receive staging — a vended URL's file survives")
    func stopKeepsMaterializedReceiveStaging() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let contents = Data("staged for a paste".utf8)
        try hostChannel.send(
            makeOfferFrame(
                generation: 3,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "kept.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await serveInboundTransfer(
            on: dialled, generation: 3, filename: "kept.txt", payload: contents, isInline: false)
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(try Data(contentsOf: staged) == contents)

        // Host policy disables sharing: the connection tears down, but the
        // staged file behind the pasteboard-vended URL survives.
        agent.applyPolicy(enabled: false, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        try await waitUntil { agent.liveChannelForTesting == nil }
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: staged) == contents)

        // A full agent stop keeps it too.
        agent.stop()
        // stop()'s teardown is queued on the main queue; run after it.
        await MainActor.run {}
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: staged) == contents)
    }

    @Test("a promised file offer is written `.currentHostOnly`, and nothing is pulled at offer time")
    func filePromiseWriteIsScopedCurrentHostOnly() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A file rep is the dangerous flavor: producing `public.file-url` on the
        // sync path materializes the whole file. Every promised item — file reps
        // included — must ride the one `.currentHostOnly` write, or the
        // continuity-pasteboard advertiser pulls the bytes at offer time with no
        // user interaction (docs/CLIPBOARD.md §3).
        try hostChannel.send(
            makeOfferFrame(
                generation: 12,
                reps: [
                    RepInfo(
                        uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        #expect(pasteboard.lastPrepareOptionsForTesting == .currentHostOnly)
        try await expectNoPull(on: dialled)
    }

    @Test("after the connection ends a cached rep still pastes and an unstaged file set is refused")
    func pasteAfterDisconnectServesTheCacheAndRefusesThePartialFileSet() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // One inline rep and two files: the inline one and the first file are
        // pasted while the host is there, the second file never is.
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let text = Data("still here".utf8)
        let fileBytes = Data(repeating: 0x5A, count: 4_096)
        try hostChannel.send(
            makeOfferFrame(
                generation: 44,
                reps: [
                    RepInfo(
                        uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(text.count),
                        isInline: true),
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(fileBytes.count), filename: "kept.txt",
                        isInline: false),
                    RepInfo(uti: txtUTI, byteCount: 512, filename: "never.txt", isInline: false),
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedItemCountForTesting == 3 }

        let textPull = lazyPull(pasteboard, forType: .string)
        try await serveInboundTransfer(
            on: dialled, generation: 44, payload: text, isInline: true)
        #expect(await textPull.value == text)

        let filePull = lazyPull(pasteboard, forType: .fileURL, itemIndex: 1)
        try await serveInboundTransfer(
            on: dialled, generation: 44, filename: "kept.txt", payload: fileBytes, isInline: false)
        #expect(await filePull.value != nil)

        // The host goes away. The promise stays on the pasteboard, held alive by
        // its own data providers.
        agent.applyPolicy(enabled: false, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        // RATIONALE: sanctioned no-signal poll of the filesystem-appearance kind
        // (docs/TESTING.md "Async waits in tests") — `liveChannelForTesting` is
        // SUT-internal state the teardown simply stops publishing, with no
        // @Observable getter and no test double to notify.
        try await waitUntil { agent.liveChannelForTesting == nil }

        // A materialized rep still pastes from the cache...
        #expect(await lazyPull(pasteboard, forType: .string).value == text)
        // ...while the file set is refused whole: `never.txt` can never arrive
        // now, so serving `kept.txt` would land a silent subset of what was
        // copied.
        #expect(await lazyPull(pasteboard, forType: .fileURL, itemIndex: 1).value == nil)
        #expect(await lazyPull(pasteboard, forType: .fileURL, itemIndex: 2).value == nil)
    }

    @Test("inbound multiple files: each rep is its own promised item; pulls don't cross-talk")
    func inboundMultipleFilesPromiseAndPull() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let bodyA = Data("first file body".utf8)
        let bodyB = Data("second file body".utf8)
        // Two non-image file reps in one offer.
        try hostChannel.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(bodyA.count), filename: "a.txt",
                        isInline: false),
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(bodyB.count), filename: "b.txt",
                        isInline: false),
                ]))
        // Two promised items, each promising exactly `.fileURL`.
        try await pasteboard.changed.wait { pasteboard.promisedItemCountForTesting == 2 }
        #expect(pasteboard.promisedTypesForTesting == [.fileURL, .fileURL])

        // Pull item 0's `.fileURL` → a connection for rep 0 (transfer_id low
        // bits 0).
        let pull0 = lazyPull(pasteboard, forType: .fileURL, itemIndex: 0)
        try await serveInboundTransfer(
            on: dialled, generation: 9, filename: "a.txt", payload: bodyA, isInline: false
        ) { request in
            #expect(request.transferID & 0xFFFF == 0)
            #expect(request.uti == txtUTI)
        }
        let staged0 = try #require(
            (await pull0.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged0.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: staged0) == bodyA)

        // Pull item 1's `.fileURL` → a distinct connection for rep 1 (low bits
        // 1), with no cache cross-talk: the second file's bytes, not the first's.
        let pull1 = lazyPull(pasteboard, forType: .fileURL, itemIndex: 1)
        try await serveInboundTransfer(
            on: dialled, generation: 9, filename: "b.txt", payload: bodyB, isInline: false
        ) { request in
            #expect(request.transferID & 0xFFFF == 1)
            #expect(request.uti == txtUTI)
        }
        let staged1 = try #require(
            (await pull1.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged1.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: staged1) == bodyB)

        // Distinct staged files, each with its own (uncrossed) contents.
        #expect(staged0 != staged1)
    }

    @Test("a ClipboardRelease landing while provideData is pulling returns nil and retracts the promise")
    func inboundPullReleasedMidPullReturnsNil() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 16, text: "released"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        // The host answers the transfer's connection with the reply describing
        // the payload, then releases the offer instead of streaming it: the
        // release cancels the live transfer and fails the pull, and its retract
        // clears the promise the fire was serving.
        let pull = lazyPull(pasteboard, forType: .string)
        let connection = try await acceptPull(on: dialled, generation: 16)
        defer { ClipboardDataConnection.end(fd: connection.fd) }
        try ClipboardDataConnection.writeFrame(
            makeTransferReplyFrame(
                transferID: connection.request.transferID, isArchive: false, isInline: true,
                totalBytes: 8),
            fd: connection.fd)
        try hostChannel.send(makeReleaseFrame(generation: 16))

        let provided = await pull.value
        #expect(provided == nil)
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.isEmpty }
        #expect(DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == nil)
    }

    // MARK: - Receive-side sanitization

    @Test("a `.fileURL` pull never resolves to a sanitized-away (smuggled) rep")
    func inboundFileURLPullSkipsSmuggledRep() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        // A hostile/buggy offer: a raw `public.file-url` smuggle rep (filename-
        // bearing, so it would be the FIRST file rep) ahead of the legit PNG file
        // rep. `promisedItems` drops the smuggle (it carries no promisable item)
        // and promises `.fileURL` for the PNG; the `.fileURL` pull MUST resolve to
        // the PNG (index 1), not the smuggle (index 0) — each promised item
        // carries its own rep index, gated by the same `isPromisable` check.
        try hostChannel.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(
                        uti: "public.file-url", byteCount: 32, filename: "smuggled", isInline: true),
                    RepInfo(
                        uti: UTType.png.identifier, byteCount: UInt64(png.count),
                        filename: "shot.png", isInline: true),
                ]))
        // Exactly the PNG's image UTI + `.fileURL` are promised (the smuggle rep
        // adds nothing); `.fileURL`'s rawValue IS "public.file-url", which is the
        // legit file-url promise for the PNG — distinct from the smuggled content
        // rep that shares that UTI. The discriminating check is the request's UTI.
        try await pasteboard.changed.wait { Set(pasteboard.promisedTypesForTesting) == [pngType, .fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await serveInboundTransfer(
            on: dialled, generation: 7, filename: "shot.png", payload: png, isInline: true
        ) { request in
            // The request must target the legit PNG rep, never the smuggled file-url
            // rep (whose UTI would be "public.file-url" if repIndex skipped the gate).
            #expect(request.uti == UTType.png.identifier)
        }
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)))
        #expect(staged.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: staged) == png)
    }

    @Test("an inbound offer never promises a transient-marker or raw file-url rep, only legit content")
    func inboundOfferSanitizesPromisedTypes() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // An offer mixing a legit inline text rep with two identity-skip reps a
        // buggy/malicious host might smuggle: a transient marker and a raw
        // `public.file-url`. The agent must promise ONLY the text type.
        try hostChannel.send(
            makeOfferFrame(
                generation: 17,
                reps: [
                    RepInfo(
                        uti: "org.nspasteboard.TransientType", byteCount: 4, isInline: true),
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 8, isInline: true),
                    RepInfo(
                        uti: "public.file-url", byteCount: 32, filename: "smuggled",
                        isInline: true),
                ]))

        // Only the legit text rep is promised; neither skip rep contributes a
        // promised type (the raw file-url never yields a `.fileURL` promise).
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }
        let promised = pasteboard.promisedTypesForTesting
        #expect(promised == [.string])
        #expect(!promised.contains(.fileURL))
        #expect(!promised.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(!promised.contains(NSPasteboard.PasteboardType("public.file-url")))
        // Pulling is lazy — the offer opens no data connection.
        try await expectNoPull(on: dialled)
    }

    // MARK: - Disk full

    @Test("disk full: the guest surfaces the failure to the host as a clipboard.paste error frame")
    func diskFullSurfacesErrorFrame() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Only 1 KiB free, so a 50 MiB file rep fails the pre-flight disk guard.
        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, freeSpaceProvider: { _ in 1024 },
            onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 13,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: 50 * 1024 * 1024, filename: "huge.bin",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        #expect(await pull.value == nil)

        // The host is told — its clipboard window may be the surface in view —
        // via a `clipboard.*` Error frame (not a request).
        let frame = try await maybeNextFrame(from: hostChannel)
        guard case .error(let error)? = frame?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: frame?.payload))")
            return
        }
        #expect(error.code == "clipboard.paste.disk.full")

        // The paste was made in this guest, so the guest's own menu names the
        // reason too, and the notice reveals it.
        try await notices.changed.wait { notices.value == 1 }
        #expect(await MainActor.run { agent.clipboardActivity } == .pasteRefused(.pasteDiskFull, pasteLimitBytes: nil))
    }

    @Test(
        "a mid-transfer abort reports its mapped failure on the guest's own menu, not only to the host",
        arguments: [
            (ClipboardStreamAbortCode.diskFull.rawValue, ClipboardErrorCode.pasteDiskFull),
            (ClipboardStreamAbortCode.stallTimeout.rawValue, ClipboardErrorCode.pasteTimeout),
            // Deliberately not a `ClipboardStreamAbortCode`: a code this build
            // cannot read must still be reported, on the generic failure.
            ("archive.error", ClipboardErrorCode.pasteFailed),
        ])
    func abortReportsOnTheGuestMenuToo(
        abortCode: String, expected: ClipboardErrorCode
    ) async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, dialled: dialled,
            onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 34,
                reps: [RepInfo(uti: txtUTI, byteCount: 1024, filename: "notes.txt", isInline: false)]
            ))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // A real pull the host then gives up on mid-payload, naming the code in
        // the trailer that ends the stream: the failure is the user's paste
        // failing, so it is answered in the guest as well as on the wire.
        let pull = lazyPull(pasteboard, forType: .fileURL)
        let connection = try await acceptPull(on: dialled, generation: 34)
        try abortTransfer(
            fd: connection.fd, transferID: connection.request.transferID, code: abortCode,
            declaredBytes: 1024)
        #expect(await pull.value == nil)

        let frame = try await maybeNextFrame(from: hostChannel)
        guard case .error(let error)? = frame?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: frame?.payload))")
            return
        }
        #expect(error.code == expected.rawValue)
        try await notices.changed.wait { notices.value == 1 }
        #expect(await MainActor.run { agent.clipboardActivity } == .pasteRefused(expected, pasteLimitBytes: nil))
    }

    // MARK: - Deadline-safe size cap (#561)

    @Test(
        "deadline cap: the refusal reaches the guest's own menu, one notice per offer, cleared by the next"
    )
    func tooLargeRaisesGuestNotice() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd,
            onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Two fires of one over-cap offer: the paste was made here, so the notice
        // is raised here — once, latched with the error frame.
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let half = UInt64(ClipboardPasteLimit.defaultBytes / 2) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 31,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: half, filename: "a.bin", isInline: false),
                    RepInfo(uti: txtUTI, byteCount: half, filename: "b.bin", isInline: false),
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedItemCountForTesting == 2 }

        #expect(await lazyPull(pasteboard, forType: .fileURL, itemIndex: 0).value == nil)
        #expect(await lazyPull(pasteboard, forType: .fileURL, itemIndex: 1).value == nil)

        try await notices.changed.wait { notices.value == 1 }
        #expect(
            await MainActor.run { agent.clipboardActivity }
                == .pasteRefused(.pasteTooLarge, pasteLimitBytes: ClipboardPasteLimit.defaultBytes))
        #expect(notices.value == 1)

        // The next offer is a fresh paste opportunity, so the refusal line goes.
        try hostChannel.send(
            makeOfferFrame(
                generation: 32,
                reps: [RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 4, isInline: true)]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }
        #expect(await MainActor.run { agent.clipboardActivity } == .offeredFromHost)
    }

    @Test(
        "deadline cap: a second paste of the same still-live over-cap offer reports again, not silently"
    )
    func secondPasteOfTheSameOfferReportsAgain() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // A manually advanced clock carries the second paste past the
        // production burst window without waiting it out.
        let clock = TestEngineClock()
        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, clock: clock,
            onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardPasteLimit.defaultBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 33,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)
        try await notices.changed.wait { notices.value == 1 }
        let first = try await maybeNextFrame(from: hostChannel)
        guard case .error(let firstError)? = first?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: first?.payload))")
            return
        }
        #expect(firstError.code == "clipboard.paste.too.large")

        // The offer is still live and the user pastes again — a new gesture, owed
        // its own answer on both surfaces rather than a silent no-op.
        clock.advance(seconds: await MainActor.run { ClipboardInboundOffers.refusalBurstWindow })
        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)
        try await notices.changed.wait { notices.value == 2 }
        let second = try await maybeNextFrame(from: hostChannel)
        guard case .error(let secondError)? = second?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: second?.payload))")
            return
        }
        #expect(secondError.code == "clipboard.paste.too.large")
    }

    @Test("the refusal line is written before the notice, so the dropdown it opens holds the line")
    func refusalIsStagedBeforeTheNoticeFires() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // The notice reads the activity the menu would render at that instant:
        // the status item rebuilds its dropdown on the click this raises, so a
        // notice raised ahead of the write would open a menu saying nothing.
        let seen = AtomicBox<ClipboardActivity>()
        let agentRef = AtomicBox<VsockGuestClipboardAgent>()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd,
            onClipboardNotice: { seen.set(agentRef.value?.clipboardActivity) })
        agentRef.set(agent)
        defer {
            agent.stop()
            agentRef.set(nil)
        }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardPasteLimit.defaultBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 35,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)
        try await seen.changed.wait { seen.value != nil }
        #expect(seen.value == .pasteRefused(.pasteTooLarge, pasteLimitBytes: ClipboardPasteLimit.defaultBytes))
    }

    @Test("a refusal recorded for a superseded offer is dropped, not written over the newer one")
    func staleRefusalDoesNotOverwriteANewerOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardPasteLimit.defaultBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 36,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }
        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)
        try await notices.changed.wait { notices.value == 1 }

        // A newer offer lands — small, live, and pastable.
        try hostChannel.send(
            makeOfferFrame(
                generation: 37,
                reps: [RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 4, isInline: true)]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }

        // The refusal hop runs after `provideData` returns, so gen 36's refusal
        // can execute once gen 37 is the live offer. Recording it must neither
        // relabel the new offer as refused nor pop the menu for a live paste.
        agent.recordPasteFailureForTesting(code: .pasteTooLarge, generation: 36)
        // Ordered behind the seam's own main-queue hop, so this reads the state
        // the dropped refusal would have written.
        let activity = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: agent.clipboardActivity) }
        }
        #expect(activity == .offeredFromHost)
        #expect(notices.value == 1)
    }

    @Test("deadline cap: a host-pushed ceiling below the default refuses what the default allowed")
    func loweredCeilingRefusesUnderTheDefault() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        let lowered = 512 * 1024 * 1024
        try await startAgentAndWaitForLiveChannel(agent: agent, maxPasteBytes: lowered)

        // Comfortably under the built-in default, so only the pushed ceiling can
        // be what refuses it.
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overLowered = UInt64(lowered) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 41,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: overLowered, filename: "big.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)
        try await expectNoPull(on: dialled)
    }

    @Test("deadline cap: raising the ceiling after a refusal does not rewrite the figure it named")
    func refusalKeepsTheCeilingItWasRefusedAt() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let notices = AtomicInt()
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, onClipboardNotice: { notices.increment() })
        defer { agent.stop() }

        let lowered = 512 * 1024 * 1024
        try await startAgentAndWaitForLiveChannel(agent: agent, maxPasteBytes: lowered)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 43,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(lowered) + 1, filename: "big.bin",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }
        #expect(await lazyPull(pasteboard, forType: .fileURL).value == nil)

        try await notices.changed.wait { notices.value == 1 }
        #expect(
            await MainActor.run { agent.clipboardActivity }
                == .pasteRefused(.pasteTooLarge, pasteLimitBytes: lowered))

        // The user raises the ceiling. The menu rebuilds on every open, so a
        // refusal that read its figure live would start naming 16 GB for a
        // payload the 512 MB ceiling refused. `applyPolicy` hops to main, so
        // these reads queue behind it rather than racing it.
        let raised = 16 * 1024 * 1024 * 1024
        agent.applyPolicy(enabled: true, maxPasteBytes: raised)
        #expect(await MainActor.run { agent.pasteLimitForTesting } == raised)
        #expect(
            await MainActor.run { agent.clipboardActivity }
                == .pasteRefused(.pasteTooLarge, pasteLimitBytes: lowered))
    }

    @Test("deadline cap: a host-pushed ceiling above the default admits what the default refused")
    func raisedCeilingAdmitsOverTheDefault() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        let raised = 16 * 1024 * 1024 * 1024
        try await startAgentAndWaitForLiveChannel(agent: agent, maxPasteBytes: raised)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overDefault = UInt64(ClipboardPasteLimit.defaultBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 42,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: overDefault, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // A real transfer opening is the proof it was admitted; abort it so the
        // pull resolves without streaming the payload in-test.
        let pull = lazyPull(pasteboard, forType: .fileURL)
        let connection = try await acceptPull(on: dialled, generation: 42)
        try abortTransfer(
            fd: connection.fd, transferID: connection.request.transferID, code: "host.abort")
        _ = await pull.value
    }

    // MARK: - Reconnect / lifecycle

    @Test("reconnect resets echo-suppression digest so agent re-offers current pasteboard")
    func reconnectResetsEchoSuppression() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setString("persistent text", forType: .string)

        let (agentFd0, remoteFd0) = try makeRawSocketPair()
        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host0 = VsockChannel(fileDescriptor: remoteFd0)
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host0.start()
        host1.start()
        defer { host0.close(); host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard,
            label: "clipboard-reconnect-test",
            clock: MonotonicEngineClock(),
            retryInterval: 0.05
        ) { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, reporter: ClipboardTransferReporter(),
            dataDialer: dialled.dialer)
        defer { agent.stop() }

        agent.start()
        // Production agents are default-disabled until host policy enables them.
        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)

        // First connection: wait for liveChannel to be published.
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Trigger a poll — agent should offer "persistent text"
        await MainActor.run { agent.checkClipboardChange() }

        let offer1Frame = try await nextFrame(from: host0)
        guard case .clipboardOffer(let offer1) = offer1Frame.payload else {
            throw TestFailure("Expected ClipboardOffer on first connection")
        }
        #expect(offer1.generation >= 1)

        // Close first connection to force reconnect
        host0.close()
        try await waitUntil { agent.liveChannelForTesting == nil }

        // Wait for second connection
        try await waitUntil { agent.liveChannelForTesting != nil }

        // After reconnect, lastSeenDigest is cleared — next poll should re-offer
        await MainActor.run { agent.checkClipboardChange() }

        let offer2Frame = try await nextFrame(from: host1)
        guard case .clipboardOffer(let offer2) = offer2Frame.payload else {
            throw TestFailure("Expected ClipboardOffer after reconnect")
        }
        #expect(offer2.generation > offer1.generation)
    }

    @Test("after a reconnect the first poll never reads the promise this agent left standing")
    func reconnectDoesNotOfferBackTheStandingPromise() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd0, remoteFd0) = try makeRawSocketPair()
        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host0 = VsockChannel(fileDescriptor: remoteFd0)
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host0.start()
        host1.start()
        defer { host0.close(); host1.close() }

        // One consumer for the second connection's wire, so the offers it
        // carries are read in order rather than through a second iterator.
        let host1Frames = FrameRecorder(channel: host1)
        defer { host1Frames.cancel() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard, label: "clipboard-promise-reconnect-test",
            clock: MonotonicEngineClock(), retryInterval: 0.05
        ) { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }
        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, reporter: ClipboardTransferReporter(),
            dataDialer: dialled.dialer)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // The Mac's copy becomes a promise on the guest pasteboard, and a paste
        // inside the guest materializes it — so its bytes are resident, exactly
        // what a poll that read the promise would find.
        let mac = "copied on the Mac"
        try host0.send(makeTextOfferFrame(generation: 1, text: mac))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }
        let paste = lazyPull(pasteboard, forType: .string)
        try await serveInboundTransfer(
            on: dialled, generation: 1, payload: Data(mac.utf8), isInline: true)
        #expect(await paste.value == Data(mac.utf8))
        #expect(pasteboard.providerInvocationCountForTesting == 1)

        // The channel goes and the agent redials. The promise stays standing —
        // its providers hold the offer's cache alive — and the change-count gate
        // is deliberately unset for the new host.
        host0.close()
        try await waitUntil { agent.liveChannelForTesting == nil }
        try await waitUntil { agent.liveChannelForTesting != nil }

        // The first poll of the new connection must leave the standing promise
        // alone: reading it would fire its providers and offer the Mac's own
        // content back as a guest copy.
        await MainActor.run { agent.checkClipboardChange() }
        #expect(pasteboard.providerInvocationCountForTesting == 1)

        // A copy the user actually makes still crosses — and because the wire is
        // ordered, an offer the poll above should never have made would arrive
        // ahead of it.
        let guestCopy = "copied in the guest"
        pasteboard.setString(guestCopy, forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        try await host1Frames.waitForFrames { !host1Frames.offers.isEmpty }

        #expect(host1Frames.offers.count == 1)
        let offered = try #require(host1Frames.offers.first)
        #expect(offered.repInfo.map(\.byteCount) == [UInt64(Data(guestCopy.utf8).count)])
    }

    /// A no-change guard that swallows the restated enable costs a full retry
    /// interval.
    ///
    /// The resume-from-saved-state ordering: the clipboard channel redials while
    /// the host's control handshake is still in flight, the host refuses it, and
    /// the policy update that follows the handshake restates a value the agent
    /// already holds — the only wake the parked loop gets.
    @Test("a policy update restating 'enabled' reconnects a refused clipboard channel")
    func restatedEnablePolicyReconnects() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd0, remoteFd0) = try makeRawSocketPair()
        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host0 = VsockChannel(fileDescriptor: remoteFd0)
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host0.start()
        host1.start()
        defer { host0.close(); host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()
        // A retry interval far past `testWaitBackstop`, so the second connect can
        // only land inside the test because the policy update woke the loop.
        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard,
            label: "clipboard-restated-policy-test",
            clock: MonotonicEngineClock(),
            retryInterval: 600
        ) { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, reporter: ClipboardTransferReporter(),
            dataDialer: dialled.dialer)
        defer { agent.stop() }

        agent.start()
        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        try await waitUntil { agent.liveChannelForTesting != nil }

        // The host hangs up, as a refused feature channel does.
        host0.close()
        try await waitUntil { agent.liveChannelForTesting == nil }

        // Same policy, second delivery — the enable the guest already applied.
        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        try await waitUntil { agent.liveChannelForTesting != nil }
        #expect(provideCount.value == 2)
    }

    // MARK: - Teardown identity (Guard #1)

    // The serve() teardown re-checks `liveChannel === channel` before tearing the
    // connection down, so a stale connection's teardown can't clobber a live one.
    // The reconnect loop serves connections strictly sequentially today, so the
    // stale branch never fires in production — these are predicate unit tests of
    // the extracted `teardownIfCurrent`, not a fabricated two-connection race.

    @Test("teardownIfCurrent ignores a stale channel — the live connection and its inbound promise survive")
    func staleChannelDoesNotTearDownLiveConnection() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Register an inbound promise on the live connection, so a wrongful
        // teardown would be observable as a nil'd generation as well as a nil
        // channel (teardownConnectionState clears both).
        try hostChannel.send(makeTextOfferFrame(generation: 77, text: "live payload"))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 77
        }

        // Capture the live channel's identity — only its reference matters here.
        let liveChannel = try #require(DispatchQueue.main.sync { agent.liveChannelForTesting })

        // A throwaway channel that was never served; teardownIfCurrent must reject
        // it by identity, leaving the live connection untouched.
        let (staleFdA, staleFdB) = try makeRawSocketPair()
        let staleChannel = VsockChannel(fileDescriptor: staleFdA)
        let staleOther = VsockChannel(fileDescriptor: staleFdB)
        defer { staleChannel.close(); staleOther.close() }

        await MainActor.run { agent.teardownIfCurrentForTesting(staleChannel) }

        // Both the live channel and its promise are intact — a failed identity
        // check would have nil'd both via teardownConnectionState.
        #expect(DispatchQueue.main.sync { agent.liveChannelForTesting } === liveChannel)
        #expect(DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 77)
    }

    @Test("teardownIfCurrent tears down when handed the live channel")
    func liveChannelTearsDownConnection() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let liveChannel = try #require(DispatchQueue.main.sync { agent.liveChannelForTesting })

        // Handed the live channel, the positive branch fires and tears it down.
        await MainActor.run { agent.teardownIfCurrentForTesting(liveChannel) }

        #expect(DispatchQueue.main.sync { agent.liveChannelForTesting } == nil)
    }

    @Test("serve publishes liveChannel synchronously so the read loop can process inbound frames immediately")
    func servePublishesLiveChannelBeforeReadLoop() async throws {
        let pasteboard = FakePasteboard()

        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // serve() enters `await MainActor.run { liveChannel = channel }` as its
        // first step on a fresh connection — before the for-await read loop.
        // The main queue must process that block BEFORE the read loop starts,
        // otherwise an inbound frame that lands while the publish is pending
        // would be dispatched against a nil liveChannel.
        //
        // After waitUntil sees liveChannel non-nil, sending an inbound offer
        // and observing the registered promise proves the read loop is running
        // and the publish committed before it.
        let provideCount = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard,
            label: "clipboard-sync-publish-test",
            clock: MonotonicEngineClock(),
            retryInterval: 0.05
        ) { _, _ in
            provideCount.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no more fds"))
        }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, reporter: ClipboardTransferReporter(),
            dataDialer: dialled.dialer)
        defer { agent.stop() }
        agent.start()
        // Production agents are default-disabled until host policy enables them.
        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)

        // Wait until publish settles. Under the current code (await MainActor.run),
        // this happens before the read loop starts.
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Snapshot on the main queue: liveChannel must be non-nil.
        // A regression back to DispatchQueue.main.async would leave a window where
        // liveChannel is still nil here, because the async dispatch may not have
        // run before the read loop already processed frames.
        let liveChannelSet = DispatchQueue.main.sync { agent.liveChannelForTesting != nil }
        #expect(
            liveChannelSet,
            "liveChannel was nil on main queue after publish — publish was not synchronous with serve()'s progression")

        // Send an offer and verify the agent registers a promise for it,
        // confirming the read loop is running and liveChannel was already set
        // when the frame arrived. The lazy offer pulls nothing, so the read
        // loop's only observable effect is the promise landing on the pasteboard.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "ping"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == 1)
        try await expectNoPull(on: dialled)
    }

    @Test("a failed pasteboard promise write clears the inbound promise generation")
    func offerWriteFailureClearsPromiseGeneration() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // The lazy handleOffer registers a promise by writing one pasteboard
        // item; force that write to fail. The agent must drop the promise so
        // the inbound generation stays nil — a partial write can't leave a
        // dangling promise behind.
        pasteboard.failNextWrite()
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "lost"))

        // The write attempt bumps the changeCount via clearContents; wait for
        // that observable side effect, then confirm no promise was retained.
        try await pasteboard.changed.wait { pasteboard.changeCount > 0 }
        try await expectNoPull(on: dialled)
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == nil)
        #expect(pasteboard.promisedTypesForTesting.isEmpty)
    }

    @Test("data-send failure to a dead peer is handled and liveChannel is cleared")
    func dataSendFailureIsHandledGracefully() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()

        // SO_NOSIGPIPE so a write to a peer-closed socket returns EPIPE rather
        // than delivering SIGPIPE to the test process.
        var noSigpipe: Int32 = 1
        _ = setsockopt(agentFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Every data connection this agent dials is answered by a peer that
        // closes it at once, so the transfer's reply is written into a dead
        // connection.
        let agent = makeAgentWithDeadDataPeer(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("guest data", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        // Queue a request in the kernel buffer, then close the host end too, so
        // neither the transfer's connection nor the control channel survives.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID,
                uti: ClipboardContent.utf8TextUTI))
        hostChannel.close()

        // The agent reads the request, dials, tries to stream, fails (peer gone),
        // and must not crash; liveChannel is cleared once the receive loop
        // observes EOF.
        try await waitUntil { agent.liveChannelForTesting == nil }
        #expect(agent.liveChannelForTesting == nil, "liveChannel should be nil after peer EOF")
    }

    /// An agent every data connection of which is already dead when it is handed
    /// over — the peer's end is closed before the dial returns, so the transfer's
    /// first write fails.
    private func makeAgentWithDeadDataPeer(
        pasteboard: FakePasteboard, agentFd: Int32
    ) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: KernovaVsockPort.clipboard, label: "clipboard-dead-peer-test", clock: MonotonicEngineClock(),
            retryInterval: 0.05
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client,
            stagingTempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true),
            reporter: ClipboardTransferReporter(),
            dataDialer: { _ in
                let (near, far) = try makeRawSocketPair()
                ClipboardDataConnection.end(fd: far)
                return near
            })
    }

    // MARK: - Policy enforcement

    @Test("Default-disabled: enabled=false is the construction state")
    func defaultDisabledAtConstruction() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, _) = try makeRawSocketPair()
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        // Sanity: read enabled flag via the test seam from the main queue.
        let isEnabled = DispatchQueue.main.sync { agent.isEnabledForTesting }
        #expect(isEnabled == false)
    }

    @Test("applyPolicy(enabled: true) brings up the connection; enabled: false tears it down")
    func applyPolicyTogglesLiveChannel() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        agent.start()

        // Without an enabling policy, no connection should come up.
        try await Task.sleep(nanoseconds: 150_000_000)
        let stillNil = DispatchQueue.main.sync { agent.liveChannelForTesting }
        #expect(stillNil == nil)

        // Enable: connection comes up.
        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Disable: liveChannel is cleared.
        agent.applyPolicy(enabled: false, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        try await waitUntil { agent.liveChannelForTesting == nil }
    }

    // MARK: - UI activity seam

    @Test("outbound offer sets clipboard activity to .offeredToHost")
    func outboundOfferSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let initial = await MainActor.run { agent.clipboardActivity }
        #expect(initial == .enabled)

        pasteboard.setString("hello", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        _ = try await awaitOffer(on: hostChannel)  // ensure the offer was sent

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .offeredToHost)
    }

    @Test("a delivered inbound paste sets clipboard activity to .receivedFromHost")
    func inboundPullSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        let payload = Data("payload".utf8)
        let pull = lazyPull(pasteboard, forType: .string)
        try await serveInboundTransfer(
            on: dialled, generation: 1, payload: payload, isInline: true)
        _ = await pull.value

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .receivedFromHost)
    }

    @Test("an inbound host offer sets clipboard activity to .offeredFromHost")
    func inboundOfferSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Registering the promise (and setting the activity) happen together in
        // handleOffer; once the promise is observable the activity is set too.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .offeredFromHost)
    }

    @Test("a host request for the guest's clipboard sets activity to .sentToHost")
    func outboundRequestSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let dialled = DialledDataConnections()
        defer { dialled.closeAll() }
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd, dialled: dialled)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("hello from guest", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let offer = try await awaitOffer(on: hostChannel)
        let info = try #require(offer.repInfo.first)

        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: offer.generation, transferID: transferID, uti: info.uti))
        // Once the transfer is read off its connection, handleRequest has run on
        // main (the dial can't precede it), so the activity is set.
        _ = try await collectOutboundTransfer(transferID: transferID, from: dialled)

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .sentToHost)
    }

    @Test("applyPolicy(enabled: false) sets activity to .disabled; re-enabling resets to .enabled")
    func applyPolicyTogglesActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)  // leaves it enabled
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)

        // `applyPolicy` applies its change in one `DispatchQueue.main.async` hop
        // and the main actor's executor is that same serial queue, so each read
        // below is ordered behind it — the state is settled when it runs, with
        // no poll and no per-iteration `main.sync`.
        agent.applyPolicy(enabled: false, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        #expect(await MainActor.run { agent.isEnabledForTesting } == false)
        #expect(await MainActor.run { agent.clipboardActivity } == .disabled)

        agent.applyPolicy(enabled: true, maxPasteBytes: ClipboardPasteLimit.defaultBytes)
        #expect(await MainActor.run { agent.isEnabledForTesting } == true)
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)
    }

    // MARK: - Lazy inbound drivers (act as the host sender)

    /// Kicks off a lazy paste off the test's main actor.
    ///
    /// The agent's `provideData` callback BLOCKS the calling thread until the
    /// streamed bytes (or a file URL) land, so it must run off the test's main
    /// actor. Returns a `Task` whose `.value` is the bytes the provider produced
    /// (the inline bytes for a UTI type, a `file://` URL string for `.fileURL`,
    /// or `nil` on abort/timeout/disk-full).
    ///
    /// The caller streams the response on the host channel concurrently — e.g.
    /// via `serveInboundTransfer` — before awaiting `.value`.
    private func lazyPull(
        _ pasteboard: FakePasteboard, forType type: NSPasteboard.PasteboardType,
        itemIndex: Int? = nil
    ) -> Task<Data?, Never> {
        // The blocking `invokeProvider` pull runs on a GCD thread, never a parked
        // cooperative slot — see `offCooperativePool` (#618).
        Task {
            await offCooperativePool { pasteboard.invokeProvider(forType: type, itemIndex: itemIndex) }
        }
    }

    /// Awaits the next `ClipboardOffer` on `channel`.
    private func awaitOffer(on channel: VsockChannel) async throws -> Kernova_V1_ClipboardOffer {
        let frame = try await nextFrame(from: channel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        return offer
    }

    /// Awaits the next `ClipboardRelease` on `channel`.
    private func awaitRelease(on channel: VsockChannel) async throws
        -> Kernova_V1_ClipboardRelease
    {
        let frame = try await nextFrame(from: channel)
        guard case .clipboardRelease(let release) = frame.payload else {
            throw TestFailure("Expected ClipboardRelease, got \(String(describing: frame.payload))")
        }
        return release
    }

    /// Takes the data connection the agent dialled for its lazy pull, with the
    /// `ClipboardTransferRequest` that opened it, and leaves it unanswered.
    ///
    /// The caller owns the descriptor. A guest never accepts a connection, so a
    /// pull *is* the connection it opens — nothing about it crosses the control
    /// channel.
    private func acceptPull(
        on connections: DialledDataConnections, generation: UInt64
    ) async throws -> (fd: Int32, request: Kernova_V1_ClipboardTransferRequest) {
        let fd = try await connections.next()
        let request = await offCooperativePool { readTransferRequest(fd: fd) }
        guard let request else {
            ClipboardDataConnection.end(fd: fd)
            throw TestFailure("A dialled data connection carried no transfer request")
        }
        guard request.generation == generation else {
            ClipboardDataConnection.end(fd: fd)
            throw TestFailure(
                "A dialled data connection pulled gen=\(request.generation), not \(generation)")
        }
        return (fd, request)
    }

    /// Answers the agent's lazy pull on the connection it dialled: the reply
    /// describing the payload, the payload, a completion trailer, then EOF.
    ///
    /// `validate` runs against the request that opened the connection. `payload`
    /// is what the user sees: an inline rep crosses raw, everything else crosses
    /// as the one-entry archive the host's sender would encode, named `filename`.
    private func serveInboundTransfer(
        on connections: DialledDataConnections, generation: UInt64, filename: String = "",
        payload: Data, isInline: Bool,
        validate: (Kernova_V1_ClipboardTransferRequest) -> Void = { _ in }
    ) async throws {
        let isArchive = !isInline
        let wire: Data
        if isArchive {
            wire = try clipboardArchiveBytes(
                of: .blob(payload, name: filename.isEmpty ? "data" : filename))
        } else {
            wire = payload
        }
        let connection = try await acceptPull(on: connections, generation: generation)
        validate(connection.request)
        let served = await offCooperativePool {
            (try? serveTransfer(
                fd: connection.fd, transferID: connection.request.transferID, payload: wire,
                isArchive: isArchive, isInline: isInline)) != nil
        }
        guard served else {
            throw TestFailure("Serving transfer \(connection.request.transferID) failed")
        }
    }

    // MARK: - Negative-wait helpers

    /// Asserts no `ClipboardOffer` arrives on `channel` within a short window.
    private func expectNoOffer(from channel: VsockChannel) async throws {
        if let frame = try await maybeNextFrame(from: channel),
            case .clipboardOffer = frame.payload
        {
            throw TestFailure("Unexpected ClipboardOffer; echo/skip suppression failed")
        }
    }

    /// Asserts the agent pulls nothing within a short window.
    ///
    /// A pull is the data connection it opens, so a dial that never happened is
    /// what "nothing was requested" looks like now.
    ///
    /// NOTE: a bounded negative wait — there is no event to await for "no
    /// connection will ever be dialled", and the agent's reaction (if any) runs
    /// on the main queue and would have been dispatched before this window
    /// elapses.
    private func expectNoPull(
        on connections: DialledDataConnections, window: TimeInterval = 0.2
    ) async throws {
        try await MonotonicEngineClock().sleep(for: window)
        guard connections.count == 0 else {
            throw TestFailure(
                "Unexpected pull: the agent dialled \(connections.count) data connection(s)")
        }
    }

    /// Reads one frame if one arrives within a short window, else returns nil.
    ///
    /// NOTE: This is a bounded negative wait. There's no event to await for "no
    /// frame will ever arrive," so a small sleep is the pragmatic backstop — the
    /// agent's reaction (if any) runs on the main queue and would have been
    /// dispatched before this window elapses.
    private func maybeNextFrame(
        from channel: VsockChannel, window: TimeInterval = 0.2
    ) async throws -> Frame? {
        let receiver = Task<Frame?, Never> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await MonotonicEngineClock().sleep(for: window)
        receiver.cancel()
        return await receiver.value
    }

    // MARK: - Image / temp-file helpers

    private func makeTestPNG() throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func writeTempFolder(name: String, files: [(String, Data)]) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaAgentFolder-\(UUID().uuidString)", isDirectory: true)
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files {
            let fileURL = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
        return folder
    }

    private func writeTempFile(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaAgentClip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

// MARK: - Thread-safe fd array

/// Sendable wrapper for an array of file descriptors used in socket provider closures.
final class FdBox: @unchecked Sendable {
    private let fds: [Int32]  // Immutable post-init; lock not needed.

    init(fds: [Int32]) {
        self.fds = fds
    }

    func fd(at index: Int) -> Int32? {
        guard index >= 0 && index < fds.count else { return nil }
        return fds[index]
    }
}
