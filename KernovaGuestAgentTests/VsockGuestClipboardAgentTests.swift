import Testing
import Foundation
import AppKit
import CryptoKit
import Darwin
import KernovaProtocol
import UniformTypeIdentifiers

// MARK: - Fake Pasteboard

/// In-memory `Pasteboard` substitute.
///
/// Stores one ordered item — (type, data) pairs — mirroring the single
/// `NSPasteboardItem` the agent reads and writes. Thread-safe via NSLock so
/// tests running on DispatchQueue.main don't race the setup thread.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChangeCount: Int = 0
    private var storedRepresentations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
    private var storedWriteFailureCount: Int = 0

    var changeCount: Int {
        lock.withLock { storedChangeCount }
    }

    var firstItemTypes: [NSPasteboard.PasteboardType] {
        lock.withLock { storedRepresentations.map(\.type) }
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        lock.withLock { storedRepresentations.first(where: { $0.type == type })?.data }
    }

    /// File URLs the last `writeItem` placed on the pasteboard (decoded from
    /// any `.fileURL` representations) — for asserting the staged-file paste path.
    var writtenFileURLs: [URL] {
        lock.withLock {
            storedRepresentations
                .filter { $0.type == .fileURL }
                .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
        }
    }

    /// Make the next `n` `writeItem` calls return `false` and skip storage
    /// updates.
    ///
    /// Lets tests model OS-level pasteboard write failures.
    func failNextWrite(times: Int = 1) {
        lock.withLock { storedWriteFailureCount += times }
    }

    @discardableResult
    func clearContents() -> Int {
        // Real NSPasteboard.clearContents() bumps the change count and returns
        // the new value. Mirror that behavior so the fake's echo-suppression
        // delta matches a real pasteboard.
        lock.withLock {
            storedRepresentations.removeAll()
            storedChangeCount += 1
            return storedChangeCount
        }
    }

    @discardableResult
    func writeItem(representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        lock.withLock {
            if storedWriteFailureCount > 0 {
                storedWriteFailureCount -= 1
                return false
            }
            storedRepresentations = representations
            storedChangeCount += 1
            return true
        }
    }

    // MARK: - String conveniences

    /// Replaces the stored item with a single text representation —
    /// equivalent to a user copying text inside the guest.
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        writeItem(representations: [(type: type, data: Data(string.utf8))])
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Test Suite

@Suite("VsockGuestClipboardAgent state machine")
struct VsockGuestClipboardAgentTests {
    // MARK: - Agent factory helpers

    /// Sets up an agent with the given pasteboard and a socket provider that
    /// returns the given fd on first call, transient failure thereafter.
    ///
    /// The short retry interval keeps the pause/resume wake-up snappy — the agent
    /// is now default-paused at construction, and `setEnabled(true)` only
    /// takes effect on the next loop iteration after the current sleep.
    private func makeAgent(
        pasteboard: FakePasteboard, agentFd: Int32,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, freeSpaceProvider: freeSpaceProvider,
            stagingTempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
    }

    /// Starts the agent, enables it (production agents are default-disabled
    /// until host policy says otherwise), and waits until `liveChannel` is
    /// published on the main queue.
    ///
    /// After this returns, callers driving
    /// `checkClipboardChange()` see a non-nil channel.
    private func startAgentAndWaitForLiveChannel(
        agent: VsockGuestClipboardAgent
    ) async throws {
        agent.start()
        agent.setEnabled(true)
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

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
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
        // Release the sender's go-signal, then collect Begin→Chunk(s)→End.
        try hostChannel.send(makeAckFrame(transferID: transferID))

        let transfer = try await collectOutboundTransfer(transferID: transferID, from: hostChannel)
        #expect(transfer.begin.uti == ClipboardContent.utf8TextUTI)
        #expect(transfer.begin.isInline)
        #expect(transfer.bytes == Data(text.utf8))
        #expect(transfer.end.totalBytes == UInt64(Data(text.utf8).count))
        #expect(transfer.end.sha256 == Data(SHA256.hash(data: Data(text.utf8))))
    }

    @Test("outbound copied file: offered by stat (no read), streamed from disk on request")
    func outboundCopiedFileOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
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
        pasteboard.writeItem(representations: [
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        // No rejection despite a file far over the old cap conceptually: the
        // offer carries the stat'd size and the real filename.
        #expect(info.byteCount == UInt64(contents.count))
        #expect(info.filename == "notes.bin")
        // A non-image file is file-only (not inlined) per shouldInline's rule.
        #expect(!info.isInline)

        // Request rep 0; the agent streams the file's bytes from disk.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        try hostChannel.send(makeAckFrame(transferID: transferID))

        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: hostChannel, timeout: .seconds(10))
        #expect(!transfer.begin.isInline)
        #expect(transfer.begin.filename == "notes.bin")
        #expect(transfer.bytes == contents)
        #expect(transfer.end.sha256 == Data(SHA256.hash(data: contents)))
    }

    @Test("a copied image file is offered inline with the image UTI")
    func outboundCopiedImageFileOffersInline() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let url = try writeTempFile(name: "picture.png", data: png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.writeItem(representations: [
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
        try hostChannel.send(makeAckFrame(transferID: transferID))
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: hostChannel)
        #expect(transfer.bytes == png)
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

        pasteboard.writeItem(representations: [
            (type: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), data: Data([1]))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        try await expectNoOffer(from: hostChannel)
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

        pasteboard.writeItem(representations: [
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

    @Test("text just written from host is not re-offered (changeCount + digest)")
    func echoSuppression() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host offers text → agent requests → host streams → agent writes pasteboard.
        try await driveInboundText(generation: 1, text: "from host", on: hostChannel)
        try await waitUntil { pasteboard.string(forType: .string) == "from host" }

        // A poll right after the host-driven write must not re-offer the content.
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

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host streams a non-image file rep; the agent materializes it under its
        // staging root and writes a .fileURL to the pasteboard.
        let contents = Data("staged file body".utf8)
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try await driveInboundFile(
            generation: 3, uti: txtUTI, filename: "notes.txt", payload: contents, on: hostChannel)

        try await waitUntil { pasteboard.firstItemTypes.contains(.fileURL) }
        let staged = try #require(pasteboard.writtenFileURLs.first)
        #expect(FileManager.default.fileExists(atPath: staged.path))

        // A poll now sees a .fileURL pointing inside the staging root; the
        // staging-path guard must skip it so it isn't offered back to the host.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    // MARK: - Inbound (agent is the receiver)

    @Test("inbound text: offer → request → streamed bytes land on the pasteboard")
    func inboundTextRoundTrip() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host announces one inline text rep.
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "clipboard payload"))

        // The agent eager-pulls it with a request.
        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        #expect(req.generation == 42)
        #expect(req.uti == ClipboardContent.utf8TextUTI)

        // Act as the host sender: stream Begin/Chunk/End. The agent's receiver
        // acks automatically; we don't need to wait for or send acks.
        let payload = Data("clipboard payload".utf8)
        try streamInbound(
            generation: 42, transferID: req.transferID, uti: req.uti, filename: "",
            isInline: true, payload: payload, on: hostChannel)

        try await waitUntil { pasteboard.string(forType: .string) == "clipboard payload" }
        #expect(pasteboard.string(forType: .string) == "clipboard payload")
    }

    @Test("inbound multi-chunk text (200 KiB) reassembles correctly")
    func inboundMultiChunkText() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // 200 KiB of deterministic ASCII so it round-trips as a string.
        let big = String(repeating: "abcdefghij", count: 20 * 1024)  // 200_000 chars
        let payload = Data(big.utf8)

        try hostChannel.send(makeTextOfferFrame(generation: 7, text: big))
        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }

        // Stream in 64 KiB chunks so the agent's receiver reassembles a multi-chunk
        // transfer.
        try streamInbound(
            generation: 7, transferID: req.transferID, uti: req.uti, filename: "",
            isInline: true, payload: payload, chunkSize: 64 * 1024, on: hostChannel)

        try await waitUntil(timeout: .seconds(10)) {
            pasteboard.string(forType: .string) == big
        }
        #expect(pasteboard.string(forType: .string) == big)
    }

    @Test("inbound file: a non-image file rep is staged and written as a file URL")
    func inboundFileStagesAndWritesFileURL() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let contents = Data("file contents on disk".utf8)
        try await driveInboundFile(
            generation: 8, uti: txtUTI, filename: "notes.txt", payload: contents, on: hostChannel)

        // The file URL lands; the contents are NOT inlined under the text UTI.
        try await waitUntil { pasteboard.firstItemTypes.contains(.fileURL) }
        #expect(!pasteboard.firstItemTypes.contains(NSPasteboard.PasteboardType(txtUTI)))
        let staged = try #require(pasteboard.writtenFileURLs.first)
        #expect(staged.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: staged) == contents)
    }

    @Test("inbound image file: inline image plus a staged file URL both land")
    func inboundImageFileInlinesAndStages() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        // An image file rep is inline (per shouldInline) yet bears a filename, so
        // both the inline image and a staged file URL land on the pasteboard.
        try await driveInboundFile(
            generation: 5, uti: UTType.png.identifier, filename: "shot.png", payload: png,
            isInline: true, on: hostChannel)

        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)) == png
        }
        #expect(pasteboard.firstItemTypes.contains(.fileURL))
        let staged = try #require(pasteboard.writtenFileURLs.first)
        #expect(staged.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: staged) == png)
    }

    @Test("inbound representations are sanitized before reaching the pasteboard")
    func inboundRepresentationsSanitized() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let pngBytes = Data([0x89, 0x50])
        let fileURLBytes = Data("file:///etc/hosts".utf8)
        // Offer two inline reps: a bare file-url marker (filtered on apply) and a
        // PNG (kept). Both are inline so neither hits the disk-capacity gate.
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(uti: "public.file-url", byteCount: UInt64(fileURLBytes.count), isInline: true),
                    RepInfo(uti: "public.png", byteCount: UInt64(pngBytes.count), isInline: true),
                ]))

        // The agent requests both reps; stream each by transfer_id.
        var requested: [UInt64: String] = [:]
        for _ in 0..<2 {
            let frame = try await nextFrame(from: hostChannel)
            guard case .clipboardRequest(let req) = frame.payload else {
                throw TestFailure("Expected ClipboardRequest, got \(String(describing: frame.payload))")
            }
            requested[req.transferID] = req.uti
        }
        for (transferID, uti) in requested {
            let payload = uti == "public.png" ? pngBytes : fileURLBytes
            try streamInbound(
                generation: 11, transferID: transferID, uti: uti, filename: "", isInline: true,
                payload: payload, on: hostChannel)
        }

        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == pngBytes
        }
        // The file-url marker was sanitized away; only the PNG remains.
        #expect(pasteboard.firstItemTypes.map(\.rawValue) == ["public.png"])
    }

    // MARK: - Disk full

    @Test("disk full: a large file rep is not requested when the volume can't hold it")
    func diskFullSkipsLargeFileRequest() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Simulate a near-full disk: only 1 KiB free.
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, freeSpaceProvider: { _ in 1024 })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Offer a 50 MiB file rep. handleOffer's hasCapacity check fails, so the
        // agent sends NO request for it — nothing to stream, nothing written.
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 12,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: 50 * 1024 * 1024, filename: "huge.bin",
                        isInline: false)
                ]))

        // No request should arrive, and pendingInbound should stay nil (the offer
        // produced no requestable reps).
        try await expectNoRequest(from: hostChannel)
        let pendingGen = DispatchQueue.main.sync { agent.pendingInboundGenerationForTesting }
        #expect(pendingGen == nil)
        #expect(pasteboard.firstItemTypes.isEmpty)
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
            port: 49152,
            label: "clipboard-reconnect-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()
        agent.setEnabled(true)  // production agents are default-disabled until host policy enables them

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
        try await waitUntil(timeout: .seconds(2)) { agent.liveChannelForTesting != nil }

        // After reconnect, lastSeenDigest is cleared — next poll should re-offer
        await MainActor.run { agent.checkClipboardChange() }

        let offer2Frame = try await nextFrame(from: host1)
        guard case .clipboardOffer(let offer2) = offer2Frame.payload else {
            throw TestFailure("Expected ClipboardOffer after reconnect")
        }
        #expect(offer2.generation > offer1.generation)
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
        // and observing the resulting request proves the read loop is running
        // and the publish committed before it.
        let provideCount = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-sync-publish-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            provideCount.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no more fds"))
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }
        agent.start()
        agent.setEnabled(true)  // production agents are default-disabled until host policy enables them

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

        // Send an offer and verify the agent processes it, confirming the read
        // loop is running and liveChannel was already set when the frame arrived.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "ping"))
        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure(
                "Expected ClipboardRequest in response to offer, got \(String(describing: requestFrame.payload))")
        }
        #expect(req.generation == 1)
    }

    @Test("handleOffer send failure leaves pendingInboundGeneration unchanged")
    func offerSendFailureDoesNotSetPendingGeneration() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, hostFd) = try makeRawSocketPair()

        // SO_NOSIGPIPE so the agent's write to a closed peer raises an error
        // rather than killing the test process with SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(agentFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let hostChannel = VsockChannel(fileDescriptor: hostFd)
        hostChannel.start()

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Push the offer into the kernel buffer, then close the host channel.
        // The agent reads the offer; its subsequent attempt to send a request
        // back fails (peer is gone), so handleOffer's catch path runs.
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "lost"))
        hostChannel.close()

        // Wait until the agent's main-queue teardown runs (liveChannel is
        // cleared). Because the main queue is FIFO, by the time liveChannel
        // becomes nil the handleOffer dispatch — which was enqueued before
        // the EOF/teardown dispatch — has already completed. This avoids the
        // vacuous-pass risk of a raw sleep: if handleOffer hasn't run yet the
        // nil assertion would pass for the wrong reason (generation was never
        // set), not because the fix works.
        try await waitUntil { agent.liveChannelForTesting == nil }

        // The fix: pendingInboundGeneration must NOT be set to 42 — state is
        // only committed inside the do-block after a successful send.
        // With the bug present this would equal 42.
        // Read on the main queue to respect the @unchecked Sendable contract
        // (all mutable state is main-queue-exclusive).
        let pendingGen = DispatchQueue.main.sync { agent.pendingInboundGenerationForTesting }
        #expect(pendingGen == nil)
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

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("guest data", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        // Queue a request in the kernel buffer, then close the host end so the
        // agent's stream reply (Begin/...) arrives at a dead peer.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID,
                uti: ClipboardContent.utf8TextUTI))
        try hostChannel.send(makeAckFrame(transferID: transferID))
        hostChannel.close()

        // The agent reads the request, tries to stream, fails (peer gone), and
        // must not crash; liveChannel is cleared once the receive loop observes EOF.
        try await waitUntil(timeout: .seconds(2)) { agent.liveChannelForTesting == nil }
        #expect(agent.liveChannelForTesting == nil, "liveChannel should be nil after peer EOF")
    }

    // MARK: - Policy enforcement

    @Test("Default-disabled: setEnabled(false) is the construction state")
    func defaultDisabledAtConstruction() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, _) = try makeRawSocketPair()
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        // Sanity: read enabled flag via the test seam from the main queue.
        let isEnabled = DispatchQueue.main.sync { agent.isEnabledForTesting }
        #expect(isEnabled == false)
    }

    @Test("setEnabled(true) brings up the connection; setEnabled(false) tears it down")
    func setEnabledTogglesLiveChannel() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        agent.start()

        // Without setEnabled(true), no connection should come up.
        try await Task.sleep(for: .milliseconds(150))
        let stillNil = DispatchQueue.main.sync { agent.liveChannelForTesting }
        #expect(stillNil == nil)

        // Enable: connection comes up.
        agent.setEnabled(true)
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Disable: liveChannel is cleared.
        agent.setEnabled(false)
        try await waitUntil { agent.liveChannelForTesting == nil }
    }

    // MARK: - Inbound drivers (act as the host sender)

    /// Streams an inbound representation to the agent (we are the host sender).
    ///
    /// The agent's `ClipboardStreamReceiver` acks each chunk automatically, so we
    /// just push `Begin`/`Chunk`(s)/`End` and let the receiver reassemble.
    private func streamInbound(
        generation: UInt64, transferID: UInt64, uti: String, filename: String, isInline: Bool,
        payload: Data, chunkSize: Int = 64 * 1024, on channel: VsockChannel
    ) throws {
        try channel.send(
            makeBeginFrame(
                generation: generation, transferID: transferID, uti: uti, totalBytes: payload.count,
                filename: filename, isInline: isInline))
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let slice = payload.subdata(in: offset..<end)
            try channel.send(makeChunkFrame(transferID: transferID, offset: offset, data: slice))
            offset = end
        }
        try channel.send(makeEndFrame(transferID: transferID, payload: payload))
    }

    /// Drives a full inbound text round-trip: offer → await request → stream.
    private func driveInboundText(
        generation: UInt64, text: String, on channel: VsockChannel
    ) async throws {
        try channel.send(makeTextOfferFrame(generation: generation, text: text))
        let requestFrame = try await nextFrame(from: channel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        try streamInbound(
            generation: generation, transferID: req.transferID, uti: req.uti, filename: "",
            isInline: true, payload: Data(text.utf8), on: channel)
    }

    /// Drives a full inbound file round-trip: offer (file rep) → await request →
    /// stream the file's bytes.
    private func driveInboundFile(
        generation: UInt64, uti: String, filename: String, payload: Data, isInline: Bool = false,
        on channel: VsockChannel
    ) async throws {
        try channel.send(
            makeOfferFrame(
                generation: generation,
                reps: [
                    RepInfo(
                        uti: uti, byteCount: UInt64(payload.count), filename: filename,
                        isInline: isInline)
                ]))
        let requestFrame = try await nextFrame(from: channel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        try streamInbound(
            generation: generation, transferID: req.transferID, uti: uti, filename: filename,
            isInline: isInline, payload: payload, on: channel)
    }

    // MARK: - Negative-wait helpers

    /// Asserts no `ClipboardOffer` arrives on `channel` within a short window.
    private func expectNoOffer(from channel: VsockChannel) async throws {
        if let frame = try await maybeNextFrame(from: channel), case .clipboardOffer = frame.payload {
            throw TestFailure("Unexpected ClipboardOffer; echo/skip suppression failed")
        }
    }

    /// Asserts no `ClipboardRequest` arrives on `channel` within a short window.
    private func expectNoRequest(from channel: VsockChannel) async throws {
        if let frame = try await maybeNextFrame(from: channel),
            case .clipboardRequest = frame.payload
        {
            throw TestFailure("Unexpected ClipboardRequest")
        }
    }

    /// Reads one frame if one arrives within a short window, else returns nil.
    ///
    /// NOTE: This is a bounded negative wait. There's no event to await for "no
    /// frame will ever arrive," so a small sleep is the pragmatic backstop — the
    /// agent's reaction (if any) runs on the main queue and would have been
    /// dispatched before this window elapses.
    private func maybeNextFrame(
        from channel: VsockChannel, window: Duration = .milliseconds(200)
    ) async throws -> Frame? {
        let receiver = Task<Frame?, Never> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: window)
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
