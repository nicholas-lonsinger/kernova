import AppKit
import Testing
import Foundation
import Darwin
import KernovaKit
import KernovaTestSupport
import UniformTypeIdentifiers
@testable import Kernova

@Suite("VsockClipboardService", .admissionGated)
@MainActor
struct VsockClipboardServiceTests {
    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        let (a, b) = try makeRawSocketPair()
        return (VsockChannel(fileDescriptor: a), VsockChannel(fileDescriptor: b))
    }

    /// Returns the raw fd pair alongside the channels so callers can set socket
    /// options (e.g. SO_NOSIGPIPE) on the fd before writes.
    private func makeRawPair() throws -> (hostFd: Int32, guestFd: Int32, host: VsockChannel, guest: VsockChannel) {
        let (hostFd, guestFd) = try makeRawSocketPair()
        return (hostFd, guestFd, VsockChannel(fileDescriptor: hostFd), VsockChannel(fileDescriptor: guestFd))
    }

    /// The `(generation << 16) | repIndex` transfer id the service derives for
    /// representation `index` of `generation` — used to build the request the
    /// service expects and to key the stream we drive back.
    private func transferID(generation: UInt64, repIndex: UInt64) -> UInt64 {
        (generation << 16) | repIndex
    }

    /// The id the **service** mints for an inbound transfer it requests.
    ///
    /// This is the outbound id plus the host direction bit [H3]; inbound tests
    /// use it so a driven reply matches the service's pending set and
    /// `req.transferID`.
    private func inboundTransferID(generation: UInt64, repIndex: UInt64) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: Int(repIndex), hostMinted: true)
    }

    // MARK: - Driving one transfer's data connection

    /// Opens one transfer's data connection into `service`, as a guest's dial
    /// does, and returns the peer's end for the test to drive.
    ///
    /// The service owns its end on every path; whatever writes on the returned
    /// descriptor closes it.
    private func openDataConnection(to service: VsockClipboardService) throws -> Int32 {
        let (peerEnd, hostEnd) = try makeRawSocketPair()
        service.acceptDataConnection(fd: hostEnd)
        return peerEnd
    }

    /// Pulls one representation from the service the way a guest does: a data
    /// connection of its own opening with the request, then the reply, the
    /// payload and the trailer that answer it.
    ///
    /// The pull blocks until the transfer ends, so it runs off this suite's main
    /// actor — the service streams onto the connection from there.
    private func pullFromService(
        _ service: VsockClipboardService, generation: UInt64, repIndex: UInt64, uti: String
    ) async throws -> ReceivedTransfer {
        let fd = try openDataConnection(to: service)
        let xid = transferID(generation: generation, repIndex: repIndex)
        let received = await offCooperativePool {
            try? pullTransfer(fd: fd, generation: generation, transferID: xid, uti: uti)
        }
        return try #require(received, "The service answered transfer \(xid) with nothing readable")
    }

    // MARK: - Lifecycle / connectivity

    @Test("Does not send Hello on start; first outbound frame is service traffic")
    func doesNotSendHelloOnStart() async throws {
        // Hello has moved to the always-on control channel
        // (`VsockControlService`). The clipboard channel emits feature
        // payloads only — verify the first outbound frame after `start()` is
        // the offer driven by `grabIfChanged`, not a Hello.
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "first")
        service.grabIfChanged()

        let received = try await nextFrame(from: guest)
        guard case .clipboardOffer = received.payload else {
            Issue.record("Expected clipboardOffer as first outbound frame, got \(String(describing: received.payload))")
            return
        }
    }

    @Test("isConnected is true after start() — no Hello required")
    func isConnectedAfterStart() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // The clipboard listener accepts the connection before the service is
        // constructed, so connectivity is equivalent to "started and not yet
        // stopped". Liveness lives on the control channel.
        #expect(service.isConnected)
    }

    @Test("A payload-less frame is dropped without closing the clipboard channel")
    func payloadLessFrameIsDropped() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        var empty = Frame()
        empty.protocolVersion = 1
        try guest.send(empty)

        // A subsequent offer still lands — proof the empty frame was dropped
        // benignly rather than treated as a wrong-port violation.
        try guest.send(makeTextOfferFrame(generation: 1, text: "still alive"))
        try await waitForChange { !service.clipboardContent.isEmpty }
    }

    // MARK: - Outbound (we grab; the service offers and streams)

    @Test("grabIfChanged sends a metadata-only offer describing each representation")
    func grabSendsOfferWithRepInfo() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let text = "hello clipboard"
        service.clipboardContent = ClipboardContent(text: text)
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        #expect(info.uti == ClipboardContent.utf8TextUTI)
        #expect(info.byteCount == UInt64(Data(text.utf8).count))
        #expect(info.isInline)  // text inlines on the pasteboard
        #expect(info.filename.isEmpty)
    }

    @Test(
        "An offered folder is estimate-only until requested, then compressed straight onto the wire"
    )
    func requestArchivesFolderAtRequestTime() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            stagingTempRoot: stagingRoot)
        service.start()
        defer { service.stop() }

        // A host-side folder in the buffer (paste/drop intake) is a source rep
        // with a stat-walk estimate — no archive exists yet.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = parent.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("readme".utf8).write(to: folder.appendingPathComponent("README.md"))
        try Data("nested".utf8).write(to: folder.appendingPathComponent("sub/n.txt"))
        service.clipboardContent = ClipboardContent(representations: [
            ClipboardContent.Representation(
                directorySourceURL: folder, estimatedByteCount: 12, filename: "Project",
                uti: "public.folder")
        ])
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        #expect(info.isDirectory)
        #expect(info.byteCount == 12)  // the estimate, not an archive size
        #expect(info.filename == "Project")
        let xid = transferID(generation: offer.generation, repIndex: 0)

        // The request starts the walk-and-compress, whose bytes go straight onto
        // the connection — no archive is ever staged.
        let received = try await pullFromService(
            service, generation: offer.generation, repIndex: 0, uti: info.uti)
        #expect(received.reply.transferID == xid)
        #expect(!received.reply.isInline)
        #expect(received.reply.isArchive)
        // The tree is compressed straight onto the wire, so its size is unknown
        // when the reply goes out; the trailer's digest is what proves every
        // byte of it arrived.
        #expect(received.reply.totalBytes == 0)
        #expect(
            received.trailer
                == ClipboardTransferTrailer(ending: .complete(digest: sha256(received.payload))))
        // Nothing was staged to send it.
        #expect(materializedFiles(under: stagingRoot).isEmpty)

        // The streamed bytes are the archive, and they extract back to the tree.
        let dest = try extractedClipboardArchive(received.payload)
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        #expect(
            try String(contentsOf: dest.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
        #expect(
            try String(contentsOf: dest.appendingPathComponent("sub/n.txt"), encoding: .utf8)
                == "nested")
    }

    @Test(
        "A folder carrying no file bytes still offers, archives on request, and streams its tree"
    )
    func requestArchivesByteFreeFolders() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Two folders a stat walk sizes at 0: one empty, one holding only a
        // subdirectory and zero-byte files. Both are ordinary Finder copies.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let empty = parent.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let scaffold = parent.appendingPathComponent("Scaffold", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scaffold.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data().write(to: scaffold.appendingPathComponent("sub/.keep"))

        service.clipboardContent = ClipboardContent(representations: [
            ClipboardContent.Representation(
                directorySourceURL: empty, estimatedByteCount: 0, filename: "Empty",
                uti: "public.folder"),
            ClipboardContent.Representation(
                directorySourceURL: scaffold, estimatedByteCount: 0, filename: "Scaffold",
                uti: "public.folder"),
        ])
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        #expect(offer.repInfo.map(\.isDirectory) == [true, true])
        #expect(offer.repInfo.map(\.byteCount) == [0, 0])
        #expect(offer.repInfo.map(\.filename) == ["Empty", "Scaffold"])

        // The zero estimate gates nothing: each rep archives at request time and
        // the streamed `.aar` rebuilds its tree.
        let emptyOut = try await pullAndExtractArchive(
            from: service, generation: offer.generation, repIndex: 0, uti: offer.repInfo[0].uti)
        defer { try? FileManager.default.removeItem(at: emptyOut.deletingLastPathComponent()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyOut.path).isEmpty)

        let scaffoldOut = try await pullAndExtractArchive(
            from: service, generation: offer.generation, repIndex: 1, uti: offer.repInfo[1].uti)
        defer { try? FileManager.default.removeItem(at: scaffoldOut.deletingLastPathComponent()) }
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: scaffoldOut.appendingPathComponent("sub").path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(
            FileManager.default.fileExists(
                atPath: scaffoldOut.appendingPathComponent("sub/.keep").path))
    }

    /// Pulls representation `repIndex` of `generation` off its own data
    /// connection and extracts the `.aar` it carried into a fresh directory it
    /// returns.
    private func pullAndExtractArchive(
        from service: VsockClipboardService, generation: UInt64, repIndex: UInt64, uti: String
    ) async throws -> URL {
        let received = try await pullFromService(
            service, generation: generation, repIndex: repIndex, uti: uti)
        #expect(received.reply.isArchive)
        #expect(received.isComplete)
        return try extractedClipboardArchive(received.payload)
    }

    @Test("A large outbound payload crosses its data connection whole and byte-exact")
    func largeOutboundStreamsOnItsOwnConnection() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Past the socket buffer and the sender's own read buffer several times
        // over, so the payload cannot cross in one write.
        let bytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.data", data: bytes)
        ])
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        let xid = transferID(generation: offer.generation, repIndex: 0)

        let received = try await pullFromService(
            service, generation: offer.generation, repIndex: 0, uti: info.uti)
        #expect(received.reply.transferID == xid)
        // An inline payload this side of the resident threshold crosses raw, so
        // its size is known when the reply goes out.
        #expect(received.reply.isInline)
        #expect(!received.reply.isArchive)
        #expect(received.reply.totalBytes == UInt64(bytes.count))
        #expect(received.payload == bytes)
        #expect(
            received.trailer
                == ClipboardTransferTrailer(ending: .complete(digest: sha256(bytes))))
    }

    @Test("grabIfChanged is suppressed when content is unchanged or empty")
    func grabSuppressionGuards() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Empty content → no offer.
        var snapshot = recorder.frames.count
        service.grabIfChanged()
        try await recorder.expectNoNewFrames(sinceCount: snapshot)

        // First non-empty content → exactly one offer.
        service.clipboardContent = ClipboardContent(text: "alpha")
        service.grabIfChanged()
        try await recorder.waitForFrameCount(snapshot + 1)
        guard case .clipboardOffer = recorder.frames[snapshot].payload else {
            Issue.record(
                "Expected clipboardOffer for 'alpha', got \(String(describing: recorder.frames[snapshot].payload))")
            return
        }
        snapshot = recorder.frames.count

        // Same content → no second offer.
        service.grabIfChanged()
        try await recorder.expectNoNewFrames(sinceCount: snapshot)

        // Fresh content → another offer.
        service.clipboardContent = ClipboardContent(text: "beta")
        service.grabIfChanged()
        try await recorder.waitForFrameCount(snapshot + 1)
        guard case .clipboardOffer = recorder.frames[snapshot].payload else {
            Issue.record(
                "Expected clipboardOffer for 'beta', got \(String(describing: recorder.frames[snapshot].payload))")
            return
        }
    }

    // MARK: - Outbound request edge cases

    @Test("handleRequest send failure is handled gracefully and leaves the service connected")
    func requestSendFailureIsHandledGracefully() async throws {
        let (hostFd, _, host, guest) = try makeRawPair()
        host.start()
        guest.start()

        // SO_NOSIGPIPE on the host channel's fd so a write to a peer-closed
        // socket surfaces as an error rather than delivering SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(hostFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "host data")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)

        // Open the pull's data connection, write the request onto it, then close
        // it — so the reply and the payload the service writes back arrive at a
        // dead peer. The control channel goes too, as an agent crash takes both.
        let dataFd = try openDataConnection(to: service)
        let generation = offer.generation
        let xid = transferID(generation: generation, repIndex: 0)
        await offCooperativePool {
            defer { ClipboardDataConnection.end(fd: dataFd) }
            try? ClipboardDataConnection.writeFrame(
                makeTransferRequestFrame(generation: generation, transferID: xid, uti: info.uti),
                fd: dataFd)
        }
        guest.close()

        // The service reads the request and tries to stream; the writes fail
        // (peer gone) and are swallowed by the sender. No SIGPIPE, no crash, and
        // isConnected stays true because only stop() clears it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.isConnected, "isConnected should remain true — only stop() clears it")
    }

    // MARK: - Inbound (lazy pull: an offer publishes placeholders; the window
    // pulls reps for preview, and Copy-to-Mac pulls the rest)

    /// Background task that plays the guest end of the channel.
    ///
    /// For every `ClipboardRequest` the host sends, it dials a data connection
    /// into the service — as a macOS guest, which only ever initiates, does —
    /// and serves the bytes registered for that `(generation, repIndex)` on it:
    /// the reply, the payload, the 33-byte trailer, then EOF. Lets a test drive
    /// `materializeForPreview()` / `materializeForCopy()` — which block on the
    /// host's pull continuations — without hand-sequencing each transfer.
    ///
    /// Reps are keyed by `(generation, repIndex)`; the responder mints the host
    /// transfer id [H3] itself so the test only supplies the payload. Requests
    /// for an unregistered rep are ignored (the host's continuation stays parked
    /// until the test tears down or supersedes).
    ///
    /// Off the main actor by construction (docs/TESTING.md): it answers while an
    /// off-main pull holds the main thread, so main-actor isolation would make it
    /// unanswerable exactly when a test needs an answer. `@unchecked Sendable` —
    /// every mutable field is read and written under `lock`, and the gates and
    /// connections it holds are thread-safe in their own right. `openConnection`
    /// bounds what "while main is held" covers.
    private final class FakeGuestResponder: @unchecked Sendable {
        /// What the connection carries.
        enum Payload {
            /// Streamed verbatim: an inline rep's raw bytes, or an archive a
            /// test built itself.
            case verbatim(Data)
            /// Wrapped in a one-entry archive at stream time, the way the
            /// sender encodes a file or an oversize inline payload.
            case archived(Data, name: String)
            /// Nothing but a reply and an abort trailer naming this code — the
            /// guest giving up on a transfer it opened.
            case aborting(rawCode: String)
        }

        /// How far into the transfer the guest gets before it stops.
        enum Hold {
            /// Serves the transfer whole.
            case whole
            /// Parks *before* the connection is opened, until
            /// `releaseReplies()` — the host's pull is in flight (slot
            /// registered, awaiter waiting) with no transfer, and so no sink,
            /// open for it. Prefer this over ``beforeTrailer`` for a non-inline
            /// rep: a stalled archive extract keeps AppleArchive's worker
            /// threads polling for the length of the hold, which on a small CI
            /// runner starves the whole process.
            case beforeReply
            /// Opens the connection and writes the reply, then stops: the
            /// receiver-side transfer is live and its payload never arrives, so
            /// a later supersession, release or cancel has something to tear
            /// down while the host's pull is parked. `finishTransfer(_:)`
            /// resolves it instead.
            case beforePayload
            /// Writes the reply and every payload byte, then parks before the
            /// trailer until `releaseTrailer()` — so a test can observe a live,
            /// mid-flight transfer (the host has taken bytes but the pull hasn't
            /// resolved).
            case beforeTrailer
        }

        struct Reply {
            /// The UTI the offer described, which the host's request must name.
            let uti: String
            let payload: Payload
            let isInline: Bool
            /// Mirrored into the reply's `is_archive`.
            let isArchive: Bool
            let hold: Hold
        }

        private let service: VsockClipboardService
        private let guest: VsockChannel
        private let lock = NSLock()
        private var replies: [UInt64: Reply] = [:]
        private var consumeTask: Task<Void, Never>?
        /// Connections whose stream stopped at its hold, by transfer id.
        private var parked: [UInt64: (connection: ParkedDataConnection, hold: Hold)] = [:]
        private var recordedRequests: [Kernova_V1_ClipboardRequest] = []
        private var replyReleased = false
        private var holdsTrailer = false
        private var isCancelled = false
        /// Ids a release named before their stream had parked, so each is
        /// finished the moment it does.
        private var latchedFinishes: Set<UInt64> = []

        /// Fires as each request arrives, before its transfer opens.
        let requested = AsyncGate()
        /// Fires as each transfer's stream parks at its hold: the guest end is
        /// open with its remainder withheld, so there is a connection to release,
        /// cancel or tear down. The reply itself is written on the connection's
        /// own queue, so this is not evidence the host has read it.
        let parkedTransfers = AsyncGate()
        /// The transfers whose data connection the host closed under a parked
        /// reply — how a receiver's cancellation reads from the guest, with
        /// nothing crossing the control channel.
        fileprivate let hostClosed = HostClosedTransfers()

        /// Every `ClipboardRequest` the host sent, in arrival order.
        var requests: [Kernova_V1_ClipboardRequest] { lock.withLock { recordedRequests } }

        /// Whether `transferID`'s stream is parked at its hold right now.
        func isParked(_ transferID: UInt64) -> Bool {
            lock.withLock { parked[transferID] != nil }
        }

        /// When `true`, every reply registered without a hold of its own parks
        /// before its trailer.
        var holdTrailer: Bool {
            get { lock.withLock { holdsTrailer } }
            set { lock.withLock { holdsTrailer = newValue } }
        }

        /// Releases every transfer parked before its trailer, so it ends — and
        /// latches the registered ones that have yet to park, so each ends as it
        /// parks.
        ///
        /// The latch names ids rather than setting a flag: a reply registered
        /// *after* this call is a hold a later part of the test asked for, and
        /// must still park.
        func releaseTrailer() {
            let held = lock.withLock { () -> [ParkedDataConnection] in
                for (xid, reply) in replies where parked[xid] == nil && holdsTrailerLocked(reply) {
                    latchedFinishes.insert(xid)
                }
                let matching = parked.filter { $0.value.hold == .beforeTrailer }
                for xid in matching.keys { parked[xid] = nil }
                return matching.values.map(\.connection)
            }
            for connection in held { connection.resume() }
        }

        /// Whether `reply` would park before its trailer. Caller holds `lock`.
        private func holdsTrailerLocked(_ reply: Reply) -> Bool {
            reply.hold == .beforeTrailer || (reply.hold == .whole && holdsTrailer)
        }

        /// Finishes one transfer parked before its payload or its trailer,
        /// writing what is left of the stream.
        ///
        /// Latches: a call that lands before ``serve(req:reply:)`` has parked
        /// the stream is applied the moment it parks, so a release is never
        /// lost to the order the test and the responder's task happened to run
        /// in — which no gate on the *request* can rule out, the request being
        /// recorded before the transfer is served.
        func finishTransfer(_ transferID: UInt64) {
            let connection = lock.withLock { () -> ParkedDataConnection? in
                guard let entry = parked.removeValue(forKey: transferID) else {
                    latchedFinishes.insert(transferID)
                    return nil
                }
                return entry.connection
            }
            connection?.resume()
        }

        private let replyGate = AsyncGate()

        /// Releases every reply registered with `.beforeReply` so it streams.
        func releaseReplies() {
            lock.withLock { replyReleased = true }
            replyGate.notify()
        }

        init(service: VsockClipboardService, guest: VsockChannel) {
            self.service = service
            self.guest = guest
        }

        /// Registers the payload to stream when the host requests
        /// `(generation, repIndex)`.
        ///
        /// `bytes` is the payload as the user sees it; an inline rep crosses
        /// raw, everything else crosses as the one-entry archive the sender
        /// would encode.
        func register(
            generation: UInt64, repIndex: UInt64, uti: String, bytes: Data,
            filename: String = "", isInline: Bool, hold: Hold = .whole
        ) {
            store(
                generation: generation, repIndex: repIndex, uti: uti,
                payload: isInline
                    ? .verbatim(bytes)
                    : .archived(bytes, name: filename.isEmpty ? "data" : filename),
                isInline: isInline, isArchive: !isInline, hold: hold)
        }

        /// Registers archive bytes to stream verbatim — a folder's tree, or a
        /// payload a test wants the extract itself to reject.
        ///
        /// The name the payload lands under comes from the offer, never the
        /// connection, so there is nothing to name here.
        func registerArchive(
            generation: UInt64, repIndex: UInt64, uti: String, archiveBytes: Data
        ) {
            store(
                generation: generation, repIndex: repIndex, uti: uti,
                payload: .verbatim(archiveBytes), isInline: false, isArchive: true, hold: .whole)
        }

        /// Registers a transfer the guest gives up on part-way: the reply, then
        /// an abort trailer naming `code` with the payload it promised unwritten.
        ///
        /// `code` is the bare wire string rather than a `ClipboardStreamAbortCode`
        /// so a test can inject one this build does not define.
        func registerAbort(generation: UInt64, repIndex: UInt64, uti: String, code: String) {
            store(
                generation: generation, repIndex: repIndex, uti: uti,
                payload: .aborting(rawCode: code), isInline: true, isArchive: false, hold: .whole)
        }

        private func store(
            generation: UInt64, repIndex: UInt64, uti: String, payload: Payload,
            isInline: Bool, isArchive: Bool, hold: Hold
        ) {
            let xid = ClipboardTransferID.make(
                generation: generation, repIndex: Int(repIndex), hostMinted: true)
            lock.withLock {
                replies[xid] = Reply(
                    uti: uti, payload: payload, isInline: isInline, isArchive: isArchive, hold: hold)
            }
        }

        /// Starts draining the channel and answering requests.
        ///
        /// The task inherits no actor, so the whole conversation — reading the
        /// request, writing the reply, streaming the payload — runs while the
        /// service under test holds the main thread.
        func start() {
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await frame in self.guest.incoming {
                        guard case .clipboardRequest(let req) = frame.payload else { continue }
                        if let reply = self.record(req) {
                            try await self.serve(req: req, reply: reply)
                        }
                    }
                } catch {
                    // Channel closed — stop answering.
                }
            }
            // A `cancel()` that landed between creating the task and taking the
            // lock has already run; storing the task then would leave a responder
            // answering after teardown, so honour the flag instead of keeping it.
            let alreadyCancelled = lock.withLock { () -> Bool in
                guard !isCancelled else { return true }
                consumeTask = task
                return false
            }
            if alreadyCancelled { task.cancel() }
        }

        /// Records one arrived request and returns the reply registered for it,
        /// announcing the arrival before anything is served.
        private func record(_ req: Kernova_V1_ClipboardRequest) -> Reply? {
            let reply = lock.withLock { () -> Reply? in
                recordedRequests.append(req)
                return replies[req.transferID]
            }
            requested.notify()
            return reply
        }

        /// Stops answering and abandons every parked connection.
        ///
        /// Synchronous and isolation-free so a `@MainActor` test can call it from
        /// a `defer`, which cannot `await` (docs/TESTING.md).
        func cancel() {
            let (task, held) = lock.withLock { () -> (Task<Void, Never>?, [ParkedDataConnection]) in
                isCancelled = true
                let task = consumeTask
                consumeTask = nil
                let held = parked.values.map(\.connection)
                parked.removeAll()
                latchedFinishes.removeAll()
                return (task, held)
            }
            task?.cancel()
            for connection in held { connection.abandon() }
        }
        deinit { consumeTask?.cancel() }

        /// Answers one request on a data connection of its own, stopping where
        /// the reply's hold says.
        private func serve(req: Kernova_V1_ClipboardRequest, reply: Reply) async throws {
            // The request names the rep the offer described; a payload answering
            // some other UTI would make its shape a coincidence.
            #expect(req.uti == reply.uti)
            let hold: Hold = reply.hold == .whole && holdTrailer ? .beforeTrailer : reply.hold
            if hold == .beforeReply {
                try await replyGate.wait { self.lock.withLock { self.replyReleased } }
            }
            let xid = req.transferID
            let wire: Data
            switch reply.payload {
            case .verbatim(let bytes):
                wire = bytes
            case .archived(let bytes, let name):
                wire = try clipboardArchiveBytes(of: .blob(bytes, name: name))
            case .aborting(let rawCode):
                let peerEnd = try openConnection()
                // A blocking write gets a thread of its own rather than one of
                // the cooperative pool's.
                Thread.detachNewThread {
                    try? abortTransfer(fd: peerEnd, transferID: xid, code: rawCode)
                }
                return
            }

            let isArchive = reply.isArchive
            let isInline = reply.isInline
            let peerEnd = try openConnection()
            guard hold == .beforePayload || hold == .beforeTrailer else {
                Thread.detachNewThread {
                    try? serveTransfer(
                        fd: peerEnd, transferID: xid, payload: wire, isArchive: isArchive,
                        isInline: isInline)
                }
                return
            }
            // An archive's size isn't known until its last byte, so the reply
            // declares 0 for one — exactly as the shipping sender does.
            let replyFrame = makeTransferReplyFrame(
                transferID: xid, isArchive: isArchive, isInline: isInline,
                totalBytes: isArchive ? 0 : wire.count)
            let trailer = ClipboardTransferTrailer(ending: .complete(digest: sha256(wire)))
            let stopsBeforePayload = hold == .beforePayload
            let connection = ParkedDataConnection(
                fd: peerEnd, transferID: xid, closed: hostClosed,
                prefix: { fd in
                    try? ClipboardDataConnection.writeFrame(replyFrame, fd: fd)
                    guard !stopsBeforePayload else { return }
                    try? writeTransferBytes(fd: fd, wire)
                },
                remainder: { fd in
                    if stopsBeforePayload { try? writeTransferBytes(fd: fd, wire) }
                    try? ClipboardDataConnection.writeTrailer(trailer, fd: fd)
                })
            // A release that already named this transfer applies here rather
            // than being dropped, so the stream ends whichever side got there
            // first.
            let alreadyReleased = lock.withLock { () -> Bool in
                guard latchedFinishes.remove(xid) == nil else { return true }
                parked[xid] = (connection: connection, hold: hold)
                return false
            }
            guard !alreadyReleased else {
                connection.resume()
                return
            }
            parkedTransfers.notify()
        }

        /// Dials one transfer's data connection into the service — the guest's
        /// half of every answer — and returns the guest's end of it.
        ///
        /// Queued onto the main actor exactly the way `VsockListenerHost` delivers
        /// an accepted connection in production, so the double's timing is the
        /// service's real timing. The guest's end is writable whenever the accept
        /// lands, so nothing here waits for it.
        ///
        /// This is what bounds the claim above: the responder answers while the
        /// main thread is held by an **off-main** pull, and by a nested wait
        /// entered at the run loop's base — not by one entered from a main-queue
        /// callout, whose drain the nested loop cannot re-enter. docs/TESTING.md
        /// forbids a test from putting a waiting pull there at all.
        private func openConnection() throws -> Int32 {
            let (peerEnd, hostEnd) = try makeRawSocketPair()
            let service = self.service
            MainActorBridge.async { service.acceptDataConnection(fd: hostEnd) }
            return peerEnd
        }
    }

    @Test("An offer publishes metadata-only .pendingRemote placeholders and sends no request")
    func offerPublishesPlaceholdersWithoutRequesting() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Record outbound frames so we can prove the offer drew no request.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        let textBytes = Data("hi".utf8)
        let fileBytes = 4_000
        try guest.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(textBytes.count), isInline: true),
                    RepInfo(uti: "public.data", byteCount: UInt64(fileBytes), filename: "doc.bin", isInline: false),
                ]))

        try await waitForChange { service.clipboardContent.representations.count == 2 }
        let reps = service.clipboardContent.representations
        // Both reps are placeholders, in the guest's offer order.
        #expect(reps.allSatisfy { $0.isPendingRemote })
        #expect(reps.map(\.uti) == [ClipboardContent.utf8TextUTI, "public.data"])
        #expect(reps.map(\.byteCount) == [textBytes.count, fileBytes])
        #expect(reps.map(\.filename) == ["", "doc.bin"])

        // No ClipboardRequest is sent at offer time — pulling is lazy.
        try await recorder.expectNoNewFrames(sinceCount: 0)
        #expect(
            recorder.first {
                if case .clipboardRequest = $0.payload { return true }; return false
            } == nil, "Offer must not trigger a ClipboardRequest")
    }

    @Test("Frames with an unsupported protocol version are dropped before dispatch")
    func dropsUnsupportedProtocolVersion() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // A v99 offer must be dropped; if the version check is missing the
        // service would publish a gen=1 placeholder.
        var offerV99 = makeTextOfferFrame(generation: 1, text: "ignored")
        offerV99.protocolVersion = 99
        try guest.send(offerV99)

        // A valid v1 offer for a different generation. Its placeholder must be
        // the one published — proof that the v99 offer was dropped.
        try guest.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.png", byteCount: 99, filename: "kept.png", isInline: false)]))

        try await waitForChange {
            service.clipboardContent.representations.first?.filename == "kept.png"
        }
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.isPendingRemote)
        #expect(rep.uti == "public.png")
    }

    @Test("materializeForPreview pulls a small inline text rep into clipboardContent")
    func previewMaterializesInlineText() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        let text = "from guest"
        let bytes = Data(text.utf8)
        responder.register(
            generation: 42, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: bytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 42,
                reps: [RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(bytes.count), isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()

        // The placeholder upgrades to the materialized inline rep.
        #expect(service.clipboardContent.text == text)
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.inMemoryData == bytes)
        // The host minted a request for the host-receives transfer id.
        let req = try #require(responder.requests.first)
        #expect(req.generation == 42)
        #expect(req.transferID == inboundTransferID(generation: 42, repIndex: 0))
        #expect(req.uti == ClipboardContent.utf8TextUTI)
    }

    @Test("materializeForPreview pulls an inline flat-RTFD rep (the image-bearing flavor)")
    func previewMaterializesFlatRTFD() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        let bytes = Data("rtfd-with-inline-image".utf8)
        responder.register(
            generation: 53, repIndex: 0, uti: UTType.flatRTFD.identifier, bytes: bytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 53,
                reps: [RepInfo(uti: UTType.flatRTFD.identifier, byteCount: UInt64(bytes.count), isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()

        // flat-RTFD does not conform to `.rtf`; before the fix it was not eagerly
        // previewable and stayed a placeholder (text-only preview). It must now be
        // pulled so the window previews the inline image.
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.inMemoryData == bytes)
        #expect(service.clipboardContent.richTextRepresentation?.uti == UTType.flatRTFD.identifier)
        let req = try #require(responder.requests.first)
        #expect(req.uti == UTType.flatRTFD.identifier)
    }

    @Test("materializeForPreview leaves non-image file and over-limit image reps as placeholders")
    func previewLeavesFileAndOversizeImagePlaceholders() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // rep 0: a small inline text → eagerly previewable, will be pulled.
        let text = "caption"
        responder.register(
            generation: 11, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        // rep 1 (non-image file) and rep 2 (over-limit image) are registered but
        // must NOT be requested by preview; register them so an erroneous pull
        // would still resolve (and thus be detectable as a non-placeholder).
        responder.register(
            generation: 11, repIndex: 1, uti: "public.data", bytes: Data(count: 4096),
            filename: "doc.bin", isInline: false)
        responder.register(
            generation: 11, repIndex: 2, uti: "public.png", bytes: Data(count: 8192),
            isInline: true)
        responder.start()

        let oversizeImage = ClipboardPreviewPolicy.maxEagerPreviewBytes + 1
        try guest.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(text.utf8.count), isInline: true),
                    RepInfo(uti: "public.data", byteCount: 4096, filename: "doc.bin", isInline: false),
                    RepInfo(uti: "public.png", byteCount: UInt64(oversizeImage), isInline: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        await service.materializeForPreview()

        let reps = service.clipboardContent.representations
        #expect(!reps[0].isPendingRemote)  // small text pulled
        #expect(reps[0].inMemoryData == Data(text.utf8))
        #expect(reps[1].isPendingRemote)  // non-image file stays a placeholder
        #expect(reps[2].isPendingRemote)  // over-limit image stays a placeholder

        // Only rep 0 was ever requested.
        #expect(responder.requests.count == 1)
        #expect(responder.requests.first?.transferID == inboundTransferID(generation: 11, repIndex: 0))
    }

    @Test("materializeForPreview is idempotent per generation — a second call pulls nothing new")
    func previewMaterializationIsIdempotent() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 4, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("x".utf8),
            isInline: true)
        responder.start()

        try guest.send(makeTextOfferFrame(generation: 4, text: "x"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "x")
        let afterFirst = responder.requests.count
        #expect(afterFirst == 1)

        // A second call for the same offer pulls nothing (guarded by
        // previewMaterializationStarted).
        await service.materializeForPreview()
        #expect(responder.requests.count == afterFirst)
    }

    @Test("an inbound concealed offer publishes concealed content and is not eagerly previewed")
    func inboundConcealedOffer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 7, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("hunter2".utf8), isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(
                        uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(Data("hunter2".utf8).count), isInline: true
                    )
                ],
                isConcealed: true))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The published content is flagged concealed so the window hides it.
        #expect(service.clipboardContent.isConcealed)

        // The eager preview pull is a no-op for concealed content: the secret is
        // never pulled into host memory just to render a preview we won't show.
        await service.materializeForPreview()
        #expect(responder.requests.isEmpty)
        #expect(service.clipboardContent.representations.first?.isPendingRemote == true)
    }

    @Test("materializeForCopy promises every rep from metadata — nothing crosses at the click")
    func copyMaterializesEveryRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("inline payload".utf8)
        let fileBytes = Data((0..<(150 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 9, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "from-guest.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(inlineBytes.count), isInline: true),
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "from-guest.bin",
                        isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Every rep — inline text included — is promised by its offer coordinates;
        // the click itself sends no request.
        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.isInline) == [true, false])
        #expect(items.promised.last?.filename == "from-guest.bin")
        #expect(responder.requests.isEmpty)

        // Each flavor pulls its bytes on demand at paste time: the inline flavor
        // through `serveData`, the file's `.fileURL` through
        // `serveFileURL` — both off the main thread here.
        let inlineData = await offCooperativePool {
            service.serveData(
                generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(inlineData == inlineBytes)
        let fileURL = await offCooperativePool {
            service.serveFileURL(generation: 9, repIndex: 1)
        }
        #expect(try Data(contentsOf: #require(fileURL)) == fileBytes)
        #expect(responder.requests.count == 2)
    }

    @Test("a promised directory rep arrives as a real folder, served unchanged on every paste")
    func copyServesStreamedDirectoryRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            stagingTempRoot: stagingRoot)
        service.start()
        defer { service.stop() }

        // The bytes the "guest" streams are the archive of a small tree, sent
        // with no declared total — the compressed size isn't knowable up front.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("MyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let aarBytes = try clipboardArchiveBytes(ofDirectoryAt: src)

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.registerArchive(
            generation: 11, repIndex: 0, uti: UTType.folder.identifier, archiveBytes: aarBytes)
        responder.start()

        // The offer carries the directory flag; the stream layer stays
        // offer-agnostic, so the service primes its receiver from it.
        try guest.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: UInt64(aarBytes.count), filename: "MyFolder",
                        isInline: false, isDirectory: true)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // The click promises the directory rep like any other — no pull, no
        // archive traffic.
        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0])
        #expect(items.promised.first?.filename == "MyFolder")
        #expect(responder.requests.isEmpty)

        // The paste-time `.fileURL` fire pulls the archive, which the transfer
        // extracted as it arrived, so a Finder paste recreates the tree.
        let url = try #require(
            await offCooperativePool { service.serveFileURL(generation: 11, repIndex: 0) })
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(url.lastPathComponent == "MyFolder")
        #expect(
            try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "x")
        // No archive was staged on the way in.
        #expect(materializedFiles(under: stagingRoot).allSatisfy { $0.pathExtension != "aar" })
        // A second paste re-serves the same tree rather than unpacking again.
        let again = try #require(
            await offCooperativePool { service.serveFileURL(generation: 11, repIndex: 0) })
        #expect(again == url)
        #expect(responder.requests.count == 1)
    }

    @Test("a directory rep offered at 0 bytes is promised and pastes as a real tree")
    func copyPromisesByteFreeDirectoryReps() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Two trees a stat walk sizes at 0 — an empty folder and one holding only
        // a subdirectory and a zero-byte file — archived as the guest would serve
        // them at request time.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let empty = src.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let scaffold = src.appendingPathComponent("Scaffold", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scaffold.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data().write(to: scaffold.appendingPathComponent("sub/.keep"))
        let emptyBytes = try clipboardArchiveBytes(ofDirectoryAt: empty)
        let scaffoldBytes = try clipboardArchiveBytes(ofDirectoryAt: scaffold)

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.registerArchive(
            generation: 12, repIndex: 0, uti: UTType.folder.identifier, archiveBytes: emptyBytes)
        responder.registerArchive(
            generation: 12, repIndex: 1, uti: UTType.folder.identifier, archiveBytes: scaffoldBytes)
        responder.start()

        // The estimate is 0 for both, which is what the wire carries — neither rep
        // may be mistaken for an empty payload and filtered away.
        try guest.send(
            makeOfferFrame(
                generation: 12,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: 0, filename: "Empty", isInline: false,
                        isDirectory: true),
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: 0, filename: "Scaffold", isInline: false,
                        isDirectory: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }
        #expect(service.clipboardContent.representations.map(\.isPendingRemote) == [true, true])

        let items = service.materializeForCopy()
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.filename) == ["Empty", "Scaffold"])
        #expect(responder.requests.isEmpty)

        let emptyURL = try #require(
            await offCooperativePool { service.serveFileURL(generation: 12, repIndex: 0) })
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: emptyURL.path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(emptyURL.lastPathComponent == "Empty")
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyURL.path).isEmpty)

        let scaffoldURL = try #require(
            await offCooperativePool { service.serveFileURL(generation: 12, repIndex: 1) })
        #expect(scaffoldURL.lastPathComponent == "Scaffold")
        #expect(
            FileManager.default.fileExists(
                atPath: scaffoldURL.appendingPathComponent("sub/.keep").path))
    }

    @Test("a paste-time fire serves the preview cache first, else the blocking pull — and caches what it pulls")
    func copyReusesPreviewMaterializedReps() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("preview me".utf8)
        let fileBytes = Data((0..<(80 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 6, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 6, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "doc.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 6,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(inlineBytes.count), isInline: true),
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "doc.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Preview pulls only rep 0 (the inline text); the file rep stays pending.
        await service.materializeForPreview()
        #expect(responder.requests.count == 1)

        // The click promises both reps from metadata — still only the one preview
        // request has gone out.
        let items = service.materializeForCopy()
        #expect(responder.requests.count == 1)
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0, 1])

        // A paste-time fire for the preview-pulled rep serves the cache — no
        // second request for it, ever.
        let cachedData = await offCooperativePool {
            service.serveData(
                generation: 6, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(cachedData == inlineBytes)
        #expect(responder.requests.count == 1)

        // The file rep misses the cache and takes the blocking-pull path — now the
        // second request goes out; nothing was ever double-requested.
        let fileURL = await offCooperativePool {
            service.serveFileURL(generation: 6, repIndex: 1)
        }
        #expect(try Data(contentsOf: #require(fileURL)) == fileBytes)
        #expect(responder.requests.count == 2)
        #expect(Set(responder.requests.map(\.transferID)).count == 2)

        // The blocking pull cached its rep too: a repeat fire re-serves the staged
        // file without a third request.
        let repeatURL = await offCooperativePool {
            service.serveFileURL(generation: 6, repIndex: 1)
        }
        #expect(repeatURL == fileURL)
        #expect(responder.requests.count == 2)
    }

    @Test("after stop(), a partially-materialized file set serves nothing and raises one issue")
    func stopRefusesPartiallyMaterializedFileSet() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("still served".utf8)
        let fileBytes = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 9, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "kept.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(inlineBytes.count), isInline: true),
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "kept.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: 512, filename: "never.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        // Materialize rep 0 and rep 1; rep 2 is never pulled, so the file set
        // {kept.bin, never.bin} is only partially materialized at the stop.
        await service.materializeForPreview()
        _ = try #require(
            await offCooperativePool { service.serveFileURL(generation: 9, repIndex: 1) })

        service.stop()

        // All-or-nothing: with never.bin unreachable, the materialized sibling
        // is refused too — a Finder paste lands no silent partial file set.
        let keptURL = await offCooperativePool {
            service.serveFileURL(generation: 9, repIndex: 1)
        }
        #expect(keptURL == nil)
        let neverURL = await offCooperativePool {
            service.serveFileURL(generation: 9, repIndex: 2)
        }
        #expect(neverURL == nil)

        // One report for the whole paste, not one per fire.
        let refusal = try #require(reports.finish)
        #expect(refusal.failure == .incompleteFileSet)
        let announcements = reports.reports.count
        _ = await offCooperativePool { service.serveFileURL(generation: 9, repIndex: 1) }
        #expect(reports.finish == refusal)
        #expect(reports.reports.count == announcements)

        // Inline flavors keep serving regardless.
        let cachedData = await offCooperativePool {
            service.serveData(generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(cachedData == inlineBytes)
    }

    @Test("a superseding offer makes the old generation unservable; its staged file rides the grace window")
    func supersedingOfferKeepsOldStagingInGraceWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(48 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 1, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "old.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "old.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let stagedURL = try #require(
            await offCooperativePool { service.serveFileURL(generation: 1, repIndex: 0) })
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // A newer offer supersedes gen=1: its coordinates stop serving, but its
        // staged file rides the maxGenerations grace window so a Finder still
        // copying out the vended URL isn't cut off.
        try guest.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))
        try await waitForChange {
            service.clipboardContent.representations.first?.filename == "new.png"
        }

        // The old coordinates serve nothing — from the cache or the wire...
        let staleURL = await offCooperativePool {
            service.serveFileURL(generation: 1, repIndex: 0)
        }
        #expect(staleURL == nil)
        let staleData = await offCooperativePool {
            service.serveData(generation: 1, repIndex: 0, uti: "public.data")
        }
        #expect(staleData == nil)
        #expect(responder.requests.count == 1, "A stale fire must not mint a new request")
        // ...but the staged file behind the already-vended URL survives the
        // supersession inside the grace window.
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: stagedURL) == fileBytes)
    }

    @Test("a ClipboardRelease makes the old generation unservable; its staged file rides the grace window")
    func releaseKeepsOldStagingInGraceWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(32 * 1024)).map { UInt8(truncatingIfNeeded: $0 &+ 5) })
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 15, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "released.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 15,
                reps: [
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "released.bin",
                        isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let stagedURL = try #require(
            await offCooperativePool { service.serveFileURL(generation: 15, repIndex: 0) })
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // The guest releases the offer — a supersession: the promise drops, but
        // the staged file rides the grace window.
        try guest.send(makeReleaseFrame(generation: 15))

        // Barrier: a control frame sent after the release, processed in order on
        // the single channel — once it surfaces, handleRelease has run.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "release processed",
            inReplyTo: "clipboard.release")
        try await reports.waitForFailure()

        let staleURL = await offCooperativePool {
            service.serveFileURL(generation: 15, repIndex: 0)
        }
        #expect(staleURL == nil)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: stagedURL) == fileBytes)
    }

    @Test("a superseding offer retracts the stale host write, surfaces the issue, and reclaims older-session roots")
    func supersedingOfferRetractsStaleHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let label = "vm-\(UUID().uuidString)"
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: label, reporter: reports.reporter, stagingTempRoot: tempRoot)

        // An earlier session's receive root, still backing the pasteboard's
        // write at start — the retraction below is what frees it.
        let olderSession = ClipboardFileStaging(label: "host-\(label)", tempRoot: tempRoot)
        let orphanURL = try olderSession.makeSink(generation: 1, filename: "orphan.bin").commit()
        service.hostPasteboardHoldsOurWrite = { true }

        var retractionResults: [Bool] = [false, true]
        var retractionCalls = 0
        service.retractStaleHostWrite = {
            retractionCalls += 1
            return retractionResults.isEmpty ? false : retractionResults.removeFirst()
        }
        service.start()
        defer { service.stop() }
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))

        // First offer: nothing of ours on the pasteboard to retract — no issue.
        try guest.send(makeTextOfferFrame(generation: 1, text: "first"))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(retractionCalls == 1)
        #expect(reports.failure == nil)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))

        // Second offer supersedes a promised write still on the pasteboard: the
        // retraction is surfaced and older-session staging is reclaimed.
        try guest.send(makeTextOfferFrame(generation: 2, text: "second"))
        try await reports.waitForFailure()
        #expect(retractionCalls == 2)
        #expect(reports.failure == .supersededCopyRetracted(hasSuccessor: true))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test("a ClipboardRelease retracts the stale host write and surfaces the issue")
    func releaseRetractsStaleHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        // Nothing to retract at the offer; the release finds the stale write.
        var retractionResults: [Bool] = [false, true]
        var retractionCalls = 0
        service.retractStaleHostWrite = {
            retractionCalls += 1
            return retractionResults.isEmpty ? false : retractionResults.removeFirst()
        }
        service.start()
        defer { service.stop() }

        try guest.send(makeTextOfferFrame(generation: 4, text: "released"))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(retractionCalls == 1)
        #expect(reports.failure == nil)

        try guest.send(makeReleaseFrame(generation: 4))
        try await reports.wait {
            reports.failure == .supersededCopyRetracted(hasSuccessor: false)
        }
        #expect(retractionCalls == 2)
    }

    @Test("stop() never retracts the host write — only supersession and release do")
    func stopDoesNotRetractHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        var retractionCalls = 0
        service.retractStaleHostWrite = {
            retractionCalls += 1
            return false
        }
        service.start()

        try guest.send(makeTextOfferFrame(generation: 1, text: "hello"))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(retractionCalls == 1)

        service.stop()
        #expect(retractionCalls == 1)
    }

    @Test("retraction clears the pasteboard only while it still holds this VM's promised write")
    func retractionRespectsPasteboardOwnership() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        // The write-only seam rather than a real `NSPasteboard`: the pasteboard
        // server is a shared system service, so a real write can fail for
        // reasons this test does not control — and `.written` is a
        // precondition of everything below it, not the subject.
        let pasteboard = FakeWritePasteboard()
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        service.retractStaleHostWrite = { publisher.retractPromisedWrite() }
        service.start()
        defer { service.stop() }

        // Guest offer gen=1, promised onto the pasteboard by Copy to Mac.
        try guest.send(
            makeOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 128, filename: "a.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        let outcome = await publisher.publish(from: service)
        guard case .written = outcome else {
            Issue.record("Expected the publish to land on the pasteboard, got \(outcome)")
            return
        }
        #expect(pasteboard.promisedItemCount > 0)

        // The guest copies again while the pasteboard still holds our write:
        // the stale promise is retracted and the issue explains.
        try guest.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.data", byteCount: 64, filename: "b.bin", isInline: false)]))
        try await reports.waitForFailure()
        #expect(pasteboard.promisedItemCount == 0)

        // Publish gen=2, then the user copies their own content over it — a
        // write of their own is a change count this publisher's write no longer
        // matches, which is the whole of what makes the pasteboard theirs.
        _ = await publisher.publish(from: service)
        pasteboard.clearContents()
        let countBefore = pasteboard.changeCount
        try guest.send(
            makeOfferFrame(
                generation: 3,
                reps: [RepInfo(uti: "public.data", byteCount: 32, filename: "c.bin", isInline: false)]))
        // Gate on gen=3 being published, which `handleOffer` does *after* it has
        // decided whether to retract — so the pasteboard reads below are ordered
        // behind that decision. Waiting for the absence of a failure instead
        // resolves on the report `handleOffer` clears on the way in, which is
        // ahead of the decision rather than behind it.
        try await waitForChange {
            service.clipboardContent.representations.first?.filename == "c.bin"
        }
        #expect(reports.failure == nil)
        // A wrongly-permissive retraction clears the pasteboard, and clearing it
        // moves the change count — so this is the whole assertion.
        #expect(pasteboard.changeCount == countBefore)
    }

    @Test("a resolved (non-promised) write is never retracted by a later offer")
    func resolvedWriteSurvivesSupersession() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        // The write-only seam, as `retractionRespectsPasteboardOwnership` uses:
        // a real pasteboard write can fail for reasons outside this test, and
        // `.written` is a precondition of everything below it.
        let pasteboard = FakeWritePasteboard()
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        service.retractStaleHostWrite = { publisher.retractPromisedWrite() }
        service.start()
        defer { service.stop() }

        // Local content with no live promise resolves at the click; its bytes
        // serve from local staging, so a guest supersession can't strand it.
        service.clipboardContent = ClipboardContent(
            representations: [
                ClipboardContent.Representation(
                    uti: ClipboardContent.utf8TextUTI, data: Data("local".utf8))
            ])
        let outcome = await publisher.publish(from: service)
        guard case .written = outcome else {
            Issue.record("Expected the publish to land on the pasteboard, got \(outcome)")
            return
        }
        let countAfterWrite = pasteboard.changeCount

        try guest.send(makeTextOfferFrame(generation: 1, text: "guest"))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }
        #expect(pasteboard.changeCount == countAfterWrite)
        #expect(reports.failure == nil)
    }

    @Test("start() reclaims an earlier session's receive root once the pasteboard no longer holds the VM's write")
    func startReclaimsSupersededSessionRoots() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let label = "vm-\(UUID().uuidString)"

        // Session 1 stages a pulled file, then stops — the file survives stop().
        let (guest1, host1) = try makePair()
        guest1.start()
        host1.start()
        defer { guest1.close() }
        let service1 = VsockClipboardService(
            channel: host1, label: label, reporter: ClipboardTransferReporter(), stagingTempRoot: tempRoot)
        service1.start()
        let fileBytes = Data((0..<(16 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(service: service1, guest: guest1)
        defer { responder.cancel() }
        responder.register(
            generation: 1, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "session1.bin", isInline: false)
        responder.start()
        try guest1.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "session1.bin",
                        isInline: false)
                ]))
        try await waitForChange { service1.clipboardContent.representations.count == 1 }
        let stagedURL = try #require(
            await offCooperativePool { service1.serveFileURL(generation: 1, repIndex: 0) })
        service1.stop()
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // Session 2, pasteboard still holding the VM's write: the older root
        // keeps backing the vended URL.
        let (guest2, host2) = try makePair()
        guest2.start()
        host2.start()
        defer { guest2.close() }
        let service2 = VsockClipboardService(
            channel: host2, label: label, reporter: ClipboardTransferReporter(), stagingTempRoot: tempRoot)
        service2.hostPasteboardHoldsOurWrite = { true }
        service2.start()
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        service2.stop()

        // Session 3, the write superseded on the pasteboard: reclaimed.
        let (guest3, host3) = try makePair()
        guest3.start()
        host3.start()
        defer { guest3.close() }
        let service3 = VsockClipboardService(
            channel: host3, label: label, reporter: ClipboardTransferReporter(), stagingTempRoot: tempRoot)
        service3.hostPasteboardHoldsOurWrite = { false }
        service3.start()
        defer { service3.stop() }
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test("the Copy-to-Mac click is metadata-only — every plain-file rep promises, no wire traffic")
    func copyDefersEveryPlainFileRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        try guest.send(
            makeOfferFrame(
                generation: 12,
                reps: [
                    RepInfo(uti: "public.data", byteCount: 10, filename: "a.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: 20, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.filename) == ["a.bin", "b.bin"])
        #expect(items.droppedReasons.isEmpty)
        // No pull at copy-click — bytes materialize on read at paste.
        #expect(responder.requests.isEmpty)
    }

    @Test("the click refuses the whole file set when its total is over the paste budget")
    func copyAdvisoryRefusesOverTotal() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Its own center rather than the process-wide `.shared` default: the
        // menu-bar surfaces render what lands *here*, so the assertions below
        // cover the service→center hop a closed clipboard window depends on.
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "Build VM", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        // Two files each under the cap but whose TOTAL exceeds it — the deadline
        // gate is all-or-nothing over the total, so the whole set is refused
        // rather than pasted piecemeal. The inline text rep still promises: only
        // paste-bound (non-inline) reps are budget-gated.
        let half = UInt64(ClipboardPasteLimit.defaultBytes) / 2 + 1
        try guest.send(
            makeOfferFrame(
                generation: 13,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 12, isInline: true),
                    RepInfo(uti: "public.data", byteCount: half, filename: "a.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: half, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0])
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        // The advisory is a metadata sum — nothing was pulled to decide it.
        #expect(responder.requests.isEmpty)
        // The refusal also lands on the VM's transfer report, the only surface
        // an automatic passthrough publish — which discards the outcome — has.
        #expect(
            reports.failure == .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes))
        #expect(reports.finish?.gesture == .copy)
        #expect(reports.finish?.peerName == "Build VM")
    }

    @Test("a lowered ceiling refuses a file set the default would have served")
    func loweredCeilingRefusesUnderTheDefault() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let lowered = 512 * 1024 * 1024
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, maxPasteBytes: { lowered })
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        // Comfortably under the built-in default, so only the injected ceiling
        // can be what refuses it.
        let overLowered = lowered + 1
        try guest.send(
            makeOfferFrame(
                generation: 51,
                reps: [
                    RepInfo(uti: "public.data", byteCount: UInt64(overLowered), filename: "a.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let items = service.materializeForCopy()
        #expect(items.droppedReasons == [.overPasteBudget])
        #expect(responder.requests.isEmpty)
        // The refusal names the ceiling actually enforced, not the default.
        #expect(reports.failure == .tooLarge(limitBytes: lowered))
    }

    @Test("a raised ceiling serves a file set the default would have refused")
    func raisedCeilingAdmitsOverTheDefault() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let raised = 16 * 1024 * 1024 * 1024
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, maxPasteBytes: { raised })
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        let overDefault = ClipboardPasteLimit.defaultBytes + 1
        try guest.send(
            makeOfferFrame(
                generation: 52,
                reps: [
                    RepInfo(uti: "public.data", byteCount: UInt64(overDefault), filename: "a.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let items = service.materializeForCopy()
        #expect(items.droppedReasons.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0])
        // Still metadata-only: admitting the set pulls nothing at the click.
        #expect(responder.requests.isEmpty)
        #expect(reports.failure == nil)
    }

    @Test("a sibling rep pulling fine does not clear the refusal the file set raised")
    func overBudgetRefusalSurvivesASuccessfulSiblingPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        // A reveal delay no scheduler stall can cross: the point is that the
        // sibling pull finishing inside the gate publishes nothing, so it cannot
        // displace the refusal — not how fast this machine happens to run.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter,
            progressRevealDelay: 3_600)
        service.start()
        defer { service.stop() }

        let noteBytes = Data("note".utf8)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 14, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: noteBytes,
            isInline: true)
        responder.start()

        // The shape that erased the refusal: over-cap files alongside a small
        // inline text rep the window previews.
        let half = UInt64(ClipboardPasteLimit.defaultBytes) / 2 + 1
        try guest.send(
            makeOfferFrame(
                generation: 14,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(noteBytes.count), isInline: true),
                    RepInfo(uti: "public.data", byteCount: half, filename: "a.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: half, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        _ = service.materializeForCopy()
        let refusal = try #require(reports.finish)
        #expect(refusal.failure == .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes))
        let publishedByTheRefusal = reports.reports.count

        // The preview pulls the text rep successfully. That says nothing about
        // the refused file set, which is still the only thing the user must act
        // on — and the pull finishes inside the reveal gate, so it publishes
        // nothing and the refusal stays up.
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "note")
        // Asserted as this operation's own contribution — it published nothing
        // — rather than as the reporter's standing slot still reading the
        // refusal. The slot is arbitrated across every operation the service
        // runs, so reading it conflates "nothing was published" with "something
        // was published and something else restored the refusal"; the recorded
        // history distinguishes them, and names what landed when it does not.
        #expect(
            reports.reports.count == publishedByTheRefusal,
            "The sibling pull published \(reports.reports.suffix(from: publishedByTheRefusal))")
        #expect(reports.finish == refusal)
    }

    @Test("a healthy pull leaves standing the refusal a superseded connection raised")
    func supersededRefusalSurvivesAHealthyPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        // A reveal delay no scheduler stall can cross: the point is that a pull
        // finishing inside the gate publishes nothing, so it cannot displace the
        // refusal — not how fast this machine happens to run.
        let service = VsockClipboardService(
            channel: host, label: "Build VM", reporter: reports.reporter,
            progressRevealDelay: 3_600)
        service.start()
        defer { service.stop() }

        let noteBytes = Data("note".utf8)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 21, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: noteBytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 21,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(noteBytes.count), isInline: true)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // The connection this one replaced: its pasteboard promise fires on a
        // paste and fails against the dead channel, well after the reconnect.
        // Reported under this VM, never seen by the live service.
        let refusal = ClipboardTransferFinish(
            gesture: .paste, outcome: .failed(.timedOut), peerName: "Build VM")
        reports.reporter.finish(refusal)

        // This service's own pull is small enough to finish inside the reveal
        // gate, so it never displaces the refusal the superseded connection
        // raised — the report belongs to the VM, not to either connection.
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "note")
        #expect(reports.finish == refusal)
    }

    @Test("each promised file rep pastes through its own blocking pull")
    func copyPromisedFilesPasteViaBlockingPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let aBytes = Data((0..<(40 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let bBytes = Data((0..<(30 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 41, repIndex: 0, uti: "public.data", bytes: aBytes, filename: "a.bin",
            isInline: false)
        responder.register(
            generation: 41, repIndex: 1, uti: "public.data", bytes: bBytes, filename: "b.bin",
            isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 41,
                reps: [
                    RepInfo(uti: "public.data", byteCount: UInt64(aBytes.count), filename: "a.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: UInt64(bBytes.count), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.droppedReasons.isEmpty)

        // Each `.fileURL` fire pulls + stages its own rep on demand, off the main
        // thread here (a paste can also fire it on main).
        let firstURL = await offCooperativePool { service.serveFileURL(generation: 41, repIndex: 0) }
        #expect(try Data(contentsOf: #require(firstURL)) == aBytes)
        let secondURL = await offCooperativePool { service.serveFileURL(generation: 41, repIndex: 1) }
        #expect(try Data(contentsOf: #require(secondURL)) == bBytes)
    }

    @Test("an image file is paste-bound too — an over-cap image set is refused whole")
    func copyRefusesOverBudgetImageFileSet() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        // Two image FILES: `is_inline` is true (they paste as images too), yet
        // each is served as `public.file-url` as well, so both count against the
        // paste budget their sum exceeds.
        let png = UTType.png.identifier
        let half = UInt64(ClipboardPasteLimit.defaultBytes) / 2 + 1
        try guest.send(
            makeOfferFrame(
                generation: 71,
                reps: [
                    RepInfo(uti: png, byteCount: half, filename: "a.png", isInline: true),
                    RepInfo(uti: png, byteCount: half, filename: "b.png", isInline: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        // All-or-nothing across the file set, reported on the surfaces a click
        // and an automatic passthrough publish each read.
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        #expect(reports.failure == .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes))
        // The cap governs the file flavor, not the inline one (§1): each rep
        // still promises, with `.fileURL` withheld from the item it plans.
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.withholdsFileURL) == [true, true])
        let specs = HostClipboardPublisher.promisedItemSpecs(for: items.promised, serve: service)
        let pngType = NSPasteboard.PasteboardType(png)
        #expect(specs.map(\.types) == [[pngType], [pngType]])

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        let bytes = Data(repeating: 0x89, count: 2048)
        responder.register(
            generation: 71, repIndex: 0, uti: png, bytes: bytes, filename: "a.png", isInline: true)
        responder.start()

        // The paste-time gate refuses a `.fileURL` fire on its own, without a
        // request; the same rep's inline flavor still serves its bytes.
        let refused = await offCooperativePool {
            service.serveFileURL(generation: 71, repIndex: 0)
        }
        #expect(refused == nil)
        #expect(responder.requests.isEmpty)
        let inline = await offCooperativePool {
            service.serveData(generation: 71, repIndex: 0, uti: png)
        }
        #expect(inline == bytes)
    }

    @Test("an under-cap image file still pastes through the `.fileURL` path")
    func underCapImageFilePastesThroughFileURL() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let png = UTType.png.identifier
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 72, repIndex: 0, uti: png, bytes: bytes, filename: "shot.png",
            isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 72,
                reps: [RepInfo(uti: png, byteCount: UInt64(bytes.count), filename: "shot.png", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let items = service.materializeForCopy()
        #expect(items.droppedReasons.isEmpty)
        #expect(items.promised.map(\.withholdsFileURL) == [false])
        let url = await offCooperativePool { service.serveFileURL(generation: 72, repIndex: 0) }
        #expect(try Data(contentsOf: #require(url)) == bytes)
    }

    @Test("a declared byte count near UInt64.max is bounded at intake, never wrapped")
    func absurdDeclaredByteCountBounded() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        try guest.send(
            makeOfferFrame(
                generation: 73,
                reps: [
                    RepInfo(uti: "public.data", byteCount: .max - 1, filename: "huge.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // The published placeholder carries the clamped size, so nothing
        // downstream sums, formats, or stages a number that can't be real.
        #expect(
            service.clipboardContent.representations[0].byteCount
                == Int(ClipboardOfferBounds.maxDeclaredByteCount))

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        let items = service.materializeForCopy()
        #expect(items.promised.isEmpty)
        #expect(items.droppedReasons == [.overPasteBudget])
        #expect(reports.failure == .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes))
        #expect(service.serveFileURL(generation: 73, repIndex: 0) == nil)
        #expect(responder.requests.isEmpty)
    }

    @Test("two reps whose declared sizes sum past UInt64 are refused, not wrapped under the cap")
    func wrappingRepSumRefused() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Unbounded, 2^63 + 2^63 wraps to 0 — a total that passes every cap.
        try guest.send(
            makeOfferFrame(
                generation: 74,
                reps: [
                    RepInfo(uti: "public.data", byteCount: 1 << 63, filename: "a.bin", isInline: false),
                    RepInfo(uti: "public.data", byteCount: 1 << 63, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        #expect(items.promised.isEmpty)
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        #expect(service.serveFileURL(generation: 74, repIndex: 0) == nil)
    }

    @Test("an offer declaring more reps than the transfer-id limit is truncated at intake")
    func repCountBoundedAtIntake() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // A rep past the 16-bit rep index a transfer id carries could never be
        // requested, so the offer is bounded to the limit the sender observes.
        let limit = ClipboardContent.maxOfferableRepresentations
        try guest.send(
            makeOfferFrame(
                generation: 75,
                reps: (0..<(limit + 3)).map { index in
                    RepInfo(uti: "public.data", byteCount: 4, filename: "f\(index).bin", isInline: false)
                }))
        try await waitForChange { service.clipboardContent.representations.count == limit }
        #expect(service.materializeForCopy().count == limit)
    }

    @Test(
        "the paste-time Copy-to-Mac pull shows an aggregate readout, cleared at the terminal (#354, #652)"
    )
    func syncCopyToMacPullShowsProgress() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Reveal instantly so the mid-flight transfer surfaces (the sanctioned
        // "drive the shown path" test value; see VsockClipboardService's doc).
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, progressRevealDelay: 0,
            progressIdleGap: 0)
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // Park before the trailer so the transfer is live (bytes received, pull
        // unresolved) while we observe the bar.
        responder.holdTrailer = true
        responder.register(
            generation: 41, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "big.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 41,
                reps: [
                    RepInfo(
                        uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "big.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let pull = Task {
            await offCooperativePool { service.serveFileURL(generation: 41, repIndex: 0) }
        }

        // The readout reveals mid-flight: inbound, denominated by the rep's total,
        // and naming the file.
        try await reports.wait { reports.snapshot?.direction == .inbound }
        #expect(reports.snapshot?.totalBytes == UInt64(fileBytes.count))
        #expect(reports.snapshot?.currentItemName == "big.bin")
        // A paste this side performs: the readout appears, but a paste fires
        // once per item, so its per-item operation carries no Cancel to stop the
        // rest.
        #expect(reports.snapshot?.gesture == .paste)
        #expect(reports.snapshot?.isCancellable == false)

        // Releasing the trailer resolves the pull; the terminal clears the readout (§13:
        // never leave a stuck bar). Gated on the responder having parked the
        // transfer — the readout above is published host-side at `unitBegan`,
        // before the request is even sent, so it is no evidence of that.
        let heldTransfer = inboundTransferID(generation: 41, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }
        responder.releaseTrailer()
        let url = await pull.value
        #expect(url != nil)
        try await reports.wait { reports.snapshot == nil }
    }

    @Test(
        "A preview trigger landing inside a paste pull joins it: one request, and both take its bytes (#860)"
    )
    func previewTriggerInsidePastePullJoinsIt() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter,
            progressRevealDelay: 0, progressIdleGap: 0)
        service.start()
        defer { service.stop() }

        // A previewable rep: the one kind a preview trigger would pull itself.
        // The paste runs off-main (`offCooperativePool`, as every other
        // blocking-pull test does) so main stays free to fire the preview and
        // then release the trailer — no dependence on the nested loop's timing.
        let text = "shared by paste and preview"
        let bytes = Data(text.utf8)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.holdTrailer = true
        responder.register(
            generation: 44, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: bytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 44,
                reps: [RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(bytes.count), isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let pull = Task {
            await offCooperativePool {
                service.serveData(generation: 44, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
            }
        }
        // Wait until the paste's transfer is live (its progress revealed), then
        // trigger the preview into the parked pull.
        try await reports.wait { reports.snapshot?.direction == .inbound }
        // …and until the responder has actually parked it. The readout above
        // cannot stand in for that: it is published host-side at `unitBegan`,
        // before the request is even sent.
        let heldTransfer = inboundTransferID(generation: 44, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }
        let preview = Task { await service.materializeForPreview() }
        // RATIONALE: sanctioned no-signal poll (docs/TESTING.md "Async waits in
        // tests") — the waiter count is NSLock-guarded SUT state, not
        // @Observable, and nothing the test owns fires when a pull is joined.
        try await waitUntil {
            service.inboundPullWaiterCountForTesting(generation: 44, repIndex: 0) == 2
        }
        responder.releaseTrailer()
        let data = await pull.value
        await preview.value

        // One request covered both: the paste served the bytes, and the preview
        // took the same pull's rep into the cache and republished it.
        #expect(data == bytes)
        #expect(responder.requests.count == 1)
        #expect(service.clipboardContent.text == text)
        #expect(service.clipboardContent.representations.first?.isPendingRemote == false)
    }

    @Test("a second paste fire that bails before its pull leaves the first fire's pull alone")
    func bailingSecondPasteFireLeavesTheFirstPullAlone() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Generous until the first fire has passed its pre-flight, then too small
        // for the second fire's — the one path a fire takes out of
        // `performBlockingPull` before it reaches the coordinator.
        let freeSpace = Box<Int64>(1 << 40)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            freeSpaceProvider: { _ in freeSpace.value })
        service.start()
        defer { service.stop() }

        let fileBytes = Data(count: 4096)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 45, repIndex: 0, uti: "public.png", bytes: fileBytes, filename: "shot.png",
            isInline: false, hold: .beforeReply)
        responder.start()

        // A paste-bound image file: named, and pre-flighted because it is not
        // inline.
        try guest.send(
            makeOfferFrame(
                generation: 45,
                reps: [
                    RepInfo(
                        uti: "public.png", byteCount: UInt64(fileBytes.count), filename: "shot.png", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let firstFire = Task {
            await offCooperativePool { service.serveFileURL(generation: 45, repIndex: 0) }
        }
        try await responder.requested.wait { responder.requests.count == 1 }

        freeSpace.value = 1024 * 1024
        let secondFire = await offCooperativePool {
            service.serveFileURL(generation: 45, repIndex: 0)
        }
        // Refused at its own pre-flight, having touched neither the pull nor the
        // wire.
        #expect(secondFire == nil)
        #expect(responder.requests.count == 1)

        // Capacity back before the first fire's transfer opens: its reply runs
        // the receiver's own capacity check, and only the second fire's
        // pre-flight was meant to see the squeeze.
        freeSpace.value = 1 << 40
        responder.releaseReplies()
        #expect(await firstFire.value != nil)
        #expect(responder.requests.count == 1)
    }

    @Test("a preview Cancel leaves a paste fire pulling another rep alone")
    func previewCancelSparesAPasteFireOnAnotherRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter,
            progressRevealDelay: 0, progressIdleGap: 0)
        service.start()
        defer { service.stop() }

        // A rep each, sharing nothing: the paste pulls the file rep (named, so
        // the preview loop never asks for it) while the preview pulls the text
        // rep. The paste's transfer is the one this Cancel must not reach, and no
        // waiter list mentions it.
        let fileBytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let previewSize = 200_000
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 54, repIndex: 0, uti: "public.data", bytes: fileBytes, filename: "f.bin",
            isInline: false, hold: .beforeReply)
        responder.register(
            generation: 54, repIndex: 1, uti: ClipboardContent.utf8TextUTI,
            bytes: Data(count: previewSize), isInline: true, hold: .beforePayload)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 54,
                reps: [
                    RepInfo(uti: "public.data", byteCount: UInt64(fileBytes.count), filename: "f.bin", isInline: false),
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(previewSize), isInline: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Preview first: its payload-less reply parks that pull, so the paste's
        // is the second request on the wire.
        let preview = Task { await service.materializeForPreview() }
        let heldTransfer = inboundTransferID(generation: 54, repIndex: 1)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }
        let paste = Task {
            await offCooperativePool { service.serveFileURL(generation: 54, repIndex: 0) }
        }
        try await responder.requested.wait { responder.requests.count == 2 }
        // The paste fire's readout covers the preview's, so the Cancel acts on the
        // identity the preview's own readout carried while it was on screen.
        try await reports.wait { reports.runningSnapshot?.isCancellable == false }
        let previewReadout = try #require(reports.lastRunningSnapshot(gesture: .preview))

        #expect(reports.reporter.cancel(previewReadout.operationID))
        await preview.value
        #expect(service.clipboardContent.representations[1].isPendingRemote)

        // The paste's awaiter was never touched: answering its request serves
        // it.
        responder.releaseReplies()
        let url = try #require(await paste.value)
        #expect(try Data(contentsOf: url) == fileBytes)

        // On the wire, the preview's own pull was cancelled and nothing else
        // was: a receiver cancels by closing its end of the connection, and the
        // paste's own connection carried its payload through to the file above.
        try await responder.hostClosed.recorded.wait { !responder.hostClosed.all.isEmpty }
        #expect(responder.hostClosed.all == [inboundTransferID(generation: 54, repIndex: 1)])
    }

    @Test("the channel closing under a paste fire explains it, as stop() does")
    func channelCloseDuringPasteFireRaisesTheExplainer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 50, repIndex: 0, uti: "public.data", bytes: Data(count: 64),
            filename: "dropped.bin", isInline: false, hold: .beforePayload)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 50,
                reps: [RepInfo(uti: "public.data", byteCount: 64, filename: "dropped.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let paste = Task {
            await offCooperativePool { service.serveFileURL(generation: 50, repIndex: 0) }
        }
        let heldTransfer = inboundTransferID(generation: 50, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }

        // The peer goes away — an agent crash, not a stop on this side.
        guest.close()

        #expect(await paste.value == nil)
        try await reports.waitForFailure()
        #expect(reports.failure == .interrupted(fileCount: nil))
        #expect(reports.finish?.gesture == .paste)
    }

    @Test("a release delivered while a paste fire is pulling resolves it to nothing")
    func releaseDuringPasteFireResolvesItEmpty() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 49, repIndex: 0, uti: "public.data", bytes: Data(count: 64),
            filename: "gone.bin", isInline: false, hold: .beforePayload)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 49,
                reps: [RepInfo(uti: "public.data", byteCount: 64, filename: "gone.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        // Wired once the offer is promised, as a Copy to Mac would leave it: the
        // retract a release performs on the host pasteboard, which in production
        // reaches the very provider whose fire is running.
        let retracts = Box(0)
        service.retractStaleHostWrite = {
            retracts.value += 1
            return true
        }

        let paste = Task {
            await offCooperativePool { service.serveFileURL(generation: 49, repIndex: 0) }
        }
        // The release must land on a transfer whose connection exists, not
        // merely on a recorded request: that connection is what it tears down.
        let heldTransfer = inboundTransferID(generation: 49, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }

        try guest.send(makeReleaseFrame(generation: 49))

        // The fire returns empty rather than parking to its backstop, and the
        // release's own explainer is what stands.
        #expect(await paste.value == nil)
        try await reports.wait {
            reports.failure == .supersededCopyRetracted(hasSuccessor: false)
        }
        #expect(retracts.value == 1)
    }

    @Test("A newer offer supersedes an in-flight pull — the pull resolves to nothing, new placeholders publish")
    func newerOfferSupersedesInFlightPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // The responder answers gen=1's request with a reply **only** (no
        // payload): that registers a live transfer in the host's receiver table,
        // so the gen=2 supersede's `cancel(generation: 1)` has something to tear
        // down, which resolves the host's parked pull continuation to nil.
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // An inline rep so the preview pulls it, and a payload that never
        // arrives so the pull parks for the supersede to interrupt.
        responder.register(
            generation: 1, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("stale".utf8),
            isInline: true, hold: .beforePayload)
        responder.start()

        // First offer (gen=1) — a single inline rep, a placeholder until pulled.
        try guest.send(
            makeOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 5, isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // Start a preview that issues the gen=1 pull and parks (no payload arrives).
        let previewTask = Task { await service.materializeForPreview() }
        // Wait until the transfer's connection is open with its payload
        // withheld. That, not the request alone, is the in-flight window the
        // supersede has to interrupt.
        let heldTransfer = inboundTransferID(generation: 1, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(heldTransfer) }

        // A newer offer (gen=2) supersedes gen=1: handleOffer cancels the
        // in-flight receiver transfer, which resolves the parked pull to nil.
        try guest.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))

        // The superseded preview resolves without committing the abandoned
        // offer's rep.
        await previewTask.value

        // The new offer's placeholder is what's published.
        try await waitForChange {
            service.clipboardContent.representations.first?.filename == "new.png"
        }
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.isPendingRemote)
        #expect(rep.uti == "public.png")
    }

    @Test("A newer offer during a SUCCESSFUL pull is suppressed — the new placeholder survives, no republish")
    func newerOfferSupersedesSuccessfulPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Unlike `newerOfferSupersedesInFlightPull` (a payload that never
        // arrives → pull resolves to nil), gen=1 answers with a COMPLETE
        // transfer, so the pull resolves with real bytes. That is the only path
        // where the `inboundPromise === promise`
        // re-check is load-bearing: a successful pull's bytes would clobber the
        // newer offer's placeholders if the guard didn't suppress the republish.
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // An inline rep so the preview pulls it through the async `materialize`
        // path (which the test seam parks).
        responder.register(
            generation: 1, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("stale".utf8),
            isInline: true)
        responder.start()

        // The seam parks the materialize call in the window between the pull
        // resolving and the guard, so the test lands a newer offer in that gap.
        let entered = AsyncGate()
        let release = AsyncGate()
        var didEnter = false
        var released = false
        var parkedOnce = false
        service.afterInboundPullForTesting = {
            // One-shot: the single gen=1 rep reaches the seam exactly once, but
            // guard defensively so a stray pull can't re-park and deadlock.
            if parkedOnce { return }
            parkedOnce = true
            didEnter = true
            entered.notify()
            try? await release.wait { released }
        }

        // gen=1 — a single inline rep, a placeholder until pulled.
        try guest.send(makeTextOfferFrame(generation: 1, text: "stale"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The preview issues the gen=1 pull; it completes and parks in the seam.
        let previewTask = Task { await service.materializeForPreview() }
        try await entered.wait { didEnter }

        // The materialize call is parked, so the main actor is free: a newer offer
        // lands and republishes gen=2's placeholder.
        try guest.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.uti == "public.png" }

        // Release: materialize resumes, the guard sees inboundPromise(gen2) !==
        // promise(gen1) and returns WITHOUT republishing gen=1's bytes.
        released = true
        release.notify()
        await previewTask.value

        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.uti == "public.png")
        #expect(rep.isPendingRemote)
    }

    @Test("stop() during a SUCCESSFUL pull keeps the rep — it caches, republishes, and stays servable")
    func stopDuringSuccessfulPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        // The test calls stop() itself mid-flow (that is the action under test);
        // this defer is an idempotent safety net for the early-throw path.
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // An inline rep so the preview pulls it through the async `materialize`
        // path (which the test seam parks).
        responder.register(
            generation: 1, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("stale".utf8),
            isInline: true)
        responder.start()

        let entered = AsyncGate()
        let release = AsyncGate()
        var didEnter = false
        var released = false
        var parkedOnce = false
        service.afterInboundPullForTesting = {
            if parkedOnce { return }
            parkedOnce = true
            didEnter = true
            entered.notify()
            try? await release.wait { released }
        }

        try guest.send(makeTextOfferFrame(generation: 1, text: "stale"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let previewTask = Task { await service.materializeForPreview() }
        try await entered.wait { didEnter }

        // stop() retains the inbound promise, so the resumed guard still sees
        // inboundPromise === promise: the completed pull's bytes land in the
        // materialization cache and republish over the placeholder — a rep
        // materialized by the time the VM stops stays servable.
        service.stop()

        released = true
        release.notify()
        await previewTask.value

        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.uti == ClipboardContent.utf8TextUTI)

        // The cached rep serves a paste-time fire after the stop.
        let served = await offCooperativePool {
            service.serveData(
                generation: 1, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(served == Data("stale".utf8))
    }

    @Test("handleRelease drops the promise — a later Copy-to-Mac resolves nothing")
    func releaseDropsPromise() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 8, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("x".utf8),
            isInline: true)
        responder.start()

        try guest.send(makeTextOfferFrame(generation: 8, text: "x"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The guest releases the offer before the host pulls anything.
        try guest.send(makeReleaseFrame(generation: 8))

        // Barrier: send a clipboard error frame *after* the release. Both are
        // control frames on the single channel, processed in order, so once the
        // error has surfaced on the VM's report, `handleRelease(gen=8)` has
        // already run and dropped the promise — making the copy below race-free.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "release processed",
            inReplyTo: "clipboard.release")
        try await reports.waitForFailure()

        // After release, the promise is gone: materializeForCopy promises nothing,
        // resolves nothing new, and never requests the rep.
        let resolved = service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)
        #expect(resolved.promised.isEmpty)
        #expect(responder.requests.isEmpty, "No rep should be requested after release")
    }

    @Test("grabIfChanged does NOT offer placeholder content; it offers once the user replaces it")
    func grabSuppressedWhileContentIsPlaceholder() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // A guest offer leaves clipboardContent holding placeholders.
        try guest.send(
            makeOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.png", byteCount: 1024, filename: "p.png", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // grabIfChanged must NOT echo placeholder content back to the guest.
        let before = recorder.frames.count
        service.grabIfChanged()
        try await recorder.expectNoNewFrames(sinceCount: before)

        // The user replaces the buffer with their own bytes → a grab now offers.
        service.clipboardContent = ClipboardContent(text: "my own text")
        service.grabIfChanged()
        try await recorder.waitForFrames {
            recorder.first {
                if case .clipboardOffer = $0.payload { return true }; return false
            } != nil
        }
    }

    @Test("clearBuffer empties and resets dedup so re-grabbing the same content re-offers")
    func clearBufferResetsDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Grab X — latches the send-dedup digest.
        service.clipboardContent = ClipboardContent(text: "keep me")
        service.grabIfChanged()
        _ = try await nextFrame(from: guest)  // first offer

        service.clearBuffer()
        #expect(service.clipboardContent.isEmpty)

        // Re-setting the SAME content and grabbing must still offer — without
        // the dedup reset the unchanged digest would silently suppress it.
        service.clipboardContent = ClipboardContent(text: "keep me")
        service.grabIfChanged()
        let frame = try await nextFrame(from: guest)
        guard case .clipboardOffer = frame.payload else {
            Issue.record("Expected clipboardOffer after clear + re-set, got \(String(describing: frame.payload))")
            return
        }
    }

    @Test("A second preview trigger during an in-flight loop sends nothing, and a later paste fire reads the cache")
    func concurrentPreviewTriggersSendOneRequest() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let payload = Data("shared payload".utf8)
        let textUTI = ClipboardContent.utf8TextUTI
        let generation: UInt64 = 17

        // Register the rep as reply-ONLY: the responder opens the transfer's
        // connection and describes the payload, but writes none of it, so the
        // host's first pull parks. That parked window is exactly when a second
        // display trigger must add nothing to the wire.
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: generation, repIndex: 0, uti: textUTI, bytes: payload,
            isInline: true, hold: .beforePayload)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: generation,
                reps: [RepInfo(uti: textUTI, byteCount: UInt64(payload.count), isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First caller: preview pull for rep 0. It sends one request and parks
        // (no payload arrives). Run it detached so the test keeps driving.
        let firstPreview = Task { await service.materializeForPreview() }

        // Wait until rep 0's connection is open and holding its payload back —
        // the in-flight window we want the second caller to coalesce into.
        let rep0XID = inboundTransferID(generation: generation, repIndex: 0)
        try await responder.parkedTransfers.wait { responder.isParked(rep0XID) }
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)

        // A second display trigger while the first loop is still parked: the
        // generation latch is set before the loop's first pull, so this one
        // returns without touching the wire.
        await service.materializeForPreview()
        #expect(
            responder.requests.filter { $0.transferID == rep0XID }.count == 1,
            "A second preview trigger must add no request while the loop runs")

        // Now complete the parked transfer: its connection is already open and
        // its reply written, so the payload and the trailer finish it.
        responder.finishTransfer(rep0XID)

        await firstPreview.value

        // The rep was pulled exactly once, and its bytes are committed to the
        // cache (republished to the buffer).
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
        #expect(service.clipboardContent.text == "shared payload")
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.inMemoryData == payload)

        // With the cache settled, a paste-time fire serves it without another
        // request.
        let pasted = await offCooperativePool {
            service.serveData(generation: generation, repIndex: 0, uti: textUTI)
        }
        #expect(pasted == payload)
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
    }

    @Test("A local edit after a guest offer wins — Copy-to-Mac copies the edit, not the stale promise")
    func localEditSupersedesInboundPromise() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 3, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("from guest".utf8), isInline: true)
        responder.start()

        try guest.send(makeTextOfferFrame(generation: 3, text: "from guest"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "from guest")

        // The user edits the guest-offered text in place (the window writes the
        // edit into the buffer). The inbound promise is now stale.
        service.clipboardContent = ClipboardContent(text: "my edit")

        // Copy-to-Mac must copy the edit, never resurrect the guest's offered rep.
        let resolved = service.materializeForCopy()
        #expect(resolved.promised.isEmpty)
        #expect(ClipboardContent(representations: resolved.resolvedReps).text == "my edit")
        #expect(resolved.resolvedReps.allSatisfy { !$0.isPendingRemote })
    }

    @Test("A failed preview pull is not retried — the generation latch is set before the loop (#879)")
    func previewDoesNotRetryAfterFailedPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // The pull is failed by the guest's own abort trailer, not the
        // lazyPullTimeout backstop, so no second clock races the test body
        // (docs/TESTING.md's injected-timeout rule).
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            lazyPullTimeout: 60)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        // The guest answers the pull by giving up on it: the transfer opens and
        // its trailer names the abort.
        let xid = inboundTransferID(generation: 2, repIndex: 0)
        responder.registerAbort(
            generation: 2, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            code: ClipboardStreamAbortCode.cancelled.rawValue)
        responder.start()

        try guest.send(makeTextOfferFrame(generation: 2, text: "retry me"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The aborted pull resolves nil and the rep stays a placeholder.
        let firstPreview = Task { await service.materializeForPreview() }
        try await responder.requested.wait {
            responder.requests.contains { $0.transferID == xid }
        }
        await firstPreview.value
        #expect(service.clipboardContent.representations.first?.isPendingRemote == true)

        // The failure raises a report, the report is an observation change, and
        // the window answers one with another trigger — which must add nothing to
        // the wire, however answerable the guest has since become.
        responder.register(
            generation: 2, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("retry me".utf8), isInline: true)
        await service.materializeForPreview()
        #expect(responder.requests.filter { $0.transferID == xid }.count == 1)
        #expect(service.clipboardContent.representations.first?.isPendingRemote == true)
    }

    @Test("An all-identity-skip offer publishes nothing and holds no promise")
    func allSkipOfferHoldsNoPromise() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        // Every rep is an identity-skip (transient marker / raw file-url).
        try guest.send(
            makeOfferFrame(
                generation: 4,
                reps: [
                    RepInfo(uti: "org.nspasteboard.TransientType", byteCount: 4, isInline: true),
                    RepInfo(uti: "public.file-url", byteCount: 8, filename: "x", isInline: true),
                ]))
        // Barrier: an error frame after the offer; once it surfaces, handleOffer ran.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "offer processed", inReplyTo: "clipboard.offer")
        try await reports.waitForFailure()

        #expect(service.clipboardContent.isEmpty)
        // No promise is held: Copy-to-Mac resolves nothing and sends no request
        // (mirrors the guest agent's all-skip handling, not a dangling promise).
        let resolved = service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)
        #expect(resolved.promised.isEmpty)
        #expect(responder.requests.isEmpty)
    }

    // MARK: - Lazy preview pull failures

    /// Drives one lazy preview pull whose transfer the guest opens and then
    /// aborts with `rawCode`, returning the refusal it reported.
    ///
    /// The preview pull has no return path to the window either — the rep stays
    /// a placeholder chip — so the report is the only account of why it never
    /// filled in.
    private func previewPullAbortedByGuest(
        rawCode: String
    ) async throws -> ClipboardTransferFinish? {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        // The guest opens the transfer and gives up part-way, its trailer naming
        // the reason — exercising the awaiter's onAbort classification (the same
        // handler the host's own mid-stream disk-full detection drives via
        // deliverAbort). An image rep is used because the preview pulls it
        // through the async `pull`.
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.registerAbort(generation: 5, repIndex: 0, uti: "public.png", code: rawCode)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 5,
                reps: [RepInfo(uti: "public.png", byteCount: 4096, filename: "shot.png", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let previewTask = Task { await service.materializeForPreview() }
        let xid = inboundTransferID(generation: 5, repIndex: 0)
        try await responder.requested.wait {
            responder.requests.contains { $0.transferID == xid }
        }

        await previewTask.value
        // The refusal crosses the operation's serial main hop, enqueued before
        // the resume `previewTask` awaited, so a block enqueued here lands
        // behind it — a deterministic hand-off, not a poll, and the one way a
        // "reported nothing" expectation can be read without racing the report.
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
        return reports.finish
    }

    private func previewPullAbortedByGuest(
        code: ClipboardStreamAbortCode
    ) async throws -> ClipboardTransferFinish? {
        try await previewPullAbortedByGuest(rawCode: code.rawValue)
    }

    @Test(
        "a preview pull aborted mid-stream reports the failed transfer",
        arguments: [
            ClipboardStreamAbortCode.readError, .digestMismatch, .sizeMismatch, .stallTimeout,
            .writeError, .payloadInvalid, .sendFailed,
        ])
    func previewPullAbortSurfacesIssue(code: ClipboardStreamAbortCode) async throws {
        let finish = try await previewPullAbortedByGuest(code: code)
        #expect(finish?.failure == .transferFailed)
        // #880: a failed preview never claims a paste happened.
        #expect(finish?.gesture == .preview)
    }

    @Test("a preview pull whose archive can't be unpacked names the unpack failure")
    func previewPullExtractAbortSurfacesUnpackFailure() async throws {
        let finish = try await previewPullAbortedByGuest(code: .extractError)
        #expect(finish?.failure == .unpackFailed)
        #expect(finish?.gesture == .preview)
    }

    // MARK: - Paste-time pull failures

    @Test("a copied item whose archive can't be unpacked reports the unpack failure")
    func pasteUnpackFailureSurfacesIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, stagingTempRoot: stagingRoot)
        service.start()
        defer { service.stop() }

        // Size and digest both agree with what arrived, so only the extract
        // itself can reject the payload.
        let notAnArchive = Data("not an archive".utf8)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.registerArchive(
            generation: 23, repIndex: 0, uti: UTType.folder.identifier, archiveBytes: notAnArchive)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 23,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: UInt64(notAnArchive.count), filename: "MyFolder",
                        isInline: false, isDirectory: true)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let url = await offCooperativePool { service.serveFileURL(generation: 23, repIndex: 0) }
        #expect(url == nil)
        try await reports.waitForFailure()
        #expect(reports.failure == .unpackFailed)
        // A streamed extract writes as it goes, so a failed one must leave
        // nothing behind for a later paste to pick up.
        #expect(materializedFiles(under: stagingRoot).isEmpty)
    }

    // MARK: - Drop staging

    /// A file representation of `url`, as the window's intake builds one for a
    /// dropped file.
    private func droppedFileContent(at url: URL) -> ClipboardContent {
        ClipboardContent(representations: [
            ClipboardContent.Representation(
                uti: "public.data", fileURL: url, byteCount: 1, filename: url.lastPathComponent)
        ])
    }

    @Test("a drop's staged files outlive the buffer that showed them and go once the offer moves on")
    func dropStagingRetiresWithItsOffer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            stagingTempRoot: tempRoot)
        service.start()
        defer { service.stop() }

        let destination = try #require(service.reserveDropDestination())
        let dropped = destination.appendingPathComponent("dropped.bin")
        try Data("x".utf8).write(to: dropped)

        // The drop becomes the buffer, then the offer the guest can pull from.
        service.clipboardContent = droppedFileContent(at: dropped)
        service.grabIfChanged()
        #expect(FileManager.default.fileExists(atPath: dropped.path))

        // Clearing the buffer leaves the offer live — the guest can still ask for
        // those bytes, so the file stays.
        service.clearBuffer()
        #expect(FileManager.default.fileExists(atPath: dropped.path))

        // A newer offer supersedes the one that read from the drop: nothing on
        // either side can reach the file now.
        service.clipboardContent = ClipboardContent(text: "typed instead")
        service.grabIfChanged()
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
    }

    @Test("a drop's staged files stay while the host pasteboard still holds this VM's write")
    func dropStagingSurvivesLiveHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            stagingTempRoot: tempRoot)
        // A "Copy to Mac" of the dropped file put its own path on the pasteboard.
        service.hostPasteboardHoldsOurWrite = { true }
        service.start()
        defer { service.stop() }

        let destination = try #require(service.reserveDropDestination())
        let dropped = destination.appendingPathComponent("dropped.bin")
        try Data("x".utf8).write(to: dropped)
        service.clipboardContent = droppedFileContent(at: dropped)
        service.grabIfChanged()

        // Buffer and offer both move on, but the pasteboard still vends the
        // dropped file's URL.
        service.clipboardContent = ClipboardContent(text: "typed instead")
        service.grabIfChanged()
        #expect(FileManager.default.fileExists(atPath: dropped.path))

        // Once the user's clipboard has moved on, the file goes.
        service.hostPasteboardHoldsOurWrite = { false }
        service.clearBuffer()
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
    }

    @Test("a drop stages under the launch-swept parent, so a stale one is reclaimed at launch")
    func dropStagingIsReclaimedAtLaunch() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter(),
            stagingTempRoot: tempRoot)
        service.start()
        defer { service.stop() }

        let destination = try #require(service.reserveDropDestination())
        let dropped = destination.appendingPathComponent("dropped.bin")
        try Data("x".utf8).write(to: dropped)
        // Held by the buffer, so nothing mid-session would reclaim it.
        service.clipboardContent = droppedFileContent(at: dropped)

        let parent = tempRoot.appendingPathComponent(
            ClipboardFileStaging.parentDirectoryName, isDirectory: true)
        #expect(dropped.path.hasPrefix(parent.path + "/"))

        // The next launch's reclaim (AppDelegate, before any staging is used)
        // sweeps what the crashed session left behind.
        ClipboardFileStaging.reclaimAll(tempRoot: tempRoot)
        #expect(!FileManager.default.fileExists(atPath: dropped.path))
    }

    // MARK: - Receive-side sanitization

    @Test("An offer carrying a transient-marker and a raw file-url rep filters them from the published placeholders")
    func offerSanitizesTransientAndFileURLReps() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // An offer mixing a legit content rep with two identity-skip reps that a
        // buggy/malicious peer might smuggle: a transient marker and a raw
        // `public.file-url`. Only the legit rep should reach `clipboardContent`.
        try guest.send(
            makeOfferFrame(
                generation: 31,
                reps: [
                    RepInfo(uti: "org.nspasteboard.TransientType", byteCount: 4, isInline: true),
                    RepInfo(uti: "public.png", byteCount: 1024, filename: "shot.png", isInline: false),
                    RepInfo(uti: "public.file-url", byteCount: 32, filename: "smuggled", isInline: true),
                ]))

        // The published placeholders exclude both identity-skip reps — only the
        // legit PNG file rep survives.
        try await waitForChange {
            service.clipboardContent.representations.map(\.uti) == ["public.png"]
        }
        let reps = service.clipboardContent.representations
        #expect(reps.count == 1)
        #expect(reps.first?.uti == "public.png")
        #expect(reps.first?.filename == "shot.png")
        #expect(reps.first?.isPendingRemote == true)
        // Neither smuggled type appears, regardless of position.
        #expect(!reps.contains { $0.uti == "org.nspasteboard.TransientType" })
        #expect(!reps.contains { $0.uti == "public.file-url" })
    }

    @Test("a zero-byte file rep survives the placeholder filter and is promised")
    func offerKeepsZeroByteFileRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // An empty file is content a native Mac-to-Mac copy carries, so it is a
        // rep like any other: the empty-payload skip reaches only *inline* reps.
        try guest.send(
            makeOfferFrame(
                generation: 33,
                reps: [
                    RepInfo(uti: "public.png", byteCount: 0, filename: "nothing.png", isInline: false),
                    RepInfo(uti: "public.png", byteCount: 1024, filename: "shot.png", isInline: false),
                ]))

        try await waitForChange {
            service.clipboardContent.representations.map(\.filename)
                == ["nothing.png", "shot.png"]
        }
        #expect(service.clipboardContent.representations[0].byteCount == 0)
        #expect(service.materializeForCopy().promised.map(\.repIndex) == [0, 1])
    }

    @Test("a zero-byte rep with no filename is still filtered from the placeholders")
    func offerFiltersZeroByteInlineRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // No filename means no file for a paste to create, so a byte-less rep is
        // an empty pasteboard flavor and carries nothing.
        try guest.send(
            makeOfferFrame(
                generation: 33,
                reps: [
                    RepInfo(uti: "public.png", byteCount: 0, isInline: true),
                    RepInfo(uti: "public.png", byteCount: 1024, filename: "shot.png", isInline: false),
                ]))

        try await waitForChange {
            service.clipboardContent.representations.map(\.filename) == ["shot.png"]
        }
        #expect(service.clipboardContent.representations.count == 1)
        #expect(service.materializeForCopy().promised.map(\.repIndex) == [1])
    }

    @Test("a fully-filtered offer keeps the shown content and holds no promise")
    func fullyFilteredOfferKeepsShownContent() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.start()

        // The window is showing content the user put there.
        let shown = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("keep me".utf8))
        ])
        service.clipboardContent = shown

        // Every rep of the guest's offer is filtered — an identity-skip type and a
        // byte-less inline rep.
        try guest.send(
            makeOfferFrame(
                generation: 41,
                reps: [
                    RepInfo(uti: "org.nspasteboard.TransientType", byteCount: 4, isInline: true),
                    RepInfo(uti: "public.png", byteCount: 0, isInline: true),
                ]))
        // Barrier: an error frame after the offer; once it surfaces, handleOffer ran.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "offer processed", inReplyTo: "clipboard.offer")
        try await reports.waitForFailure()

        // The drop leaves the shown content alone rather than publishing empty.
        #expect(service.clipboardContent.digest == shown.digest)
        #expect(service.clipboardContent.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        // No promise is held: Copy-to-Mac resolves what's shown and asks for nothing.
        let items = service.materializeForCopy()
        #expect(items.resolvedReps.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(items.promised.isEmpty)
        #expect(responder.requests.isEmpty)
    }

    // MARK: - Transfer progress

    @Test("a rep another loop pulled first is taken from the cache, not requested again (#656)")
    func coalescedRepIsNotRequestedAgain() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: ClipboardTransferReporter())
        service.start()
        defer { service.stop() }

        // Two previewable reps: a paste-time fire pulls rep 1 first, so the
        // preview never begins a transfer for it.
        let text = "the preview pulls this one itself"
        let rtf = Data(repeating: 0x41, count: 8_192)
        let responder = FakeGuestResponder(service: service, guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 7, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.register(
            generation: 7, repIndex: 1, uti: "public.rtf", bytes: rtf, isInline: true)
        responder.start()

        try guest.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: UInt64(text.utf8.count), isInline: true),
                    RepInfo(uti: "public.rtf", byteCount: UInt64(rtf.count), isInline: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // The seam parks the preview inside `materialize` after rep 0's pull,
        // leaving the main actor free for the paste-time fire.
        let entered = AsyncGate()
        let release = AsyncGate()
        var didEnter = false
        var released = false
        var parkedOnce = false
        service.afterInboundPullForTesting = {
            if parkedOnce { return }
            parkedOnce = true
            didEnter = true
            entered.notify()
            try? await release.wait { released }
        }

        // The preview begins rep 0's transfer and parks in the seam.
        let previewTask = Task { await service.materializeForPreview() }
        try await entered.wait { didEnter }

        // With it parked, a paste-time fire pulls rep 1 to completion under its
        // own operation — the rep the preview would otherwise have reached.
        let pasted = await offCooperativePool {
            service.serveData(generation: 7, repIndex: 1, uti: "public.rtf")
        }
        #expect(pasted == rtf)

        released = true
        release.notify()
        await previewTask.value

        // Reaching rep 1 and finding it already pulled, the preview takes the
        // cache: it opens no transfer for it, so it declares no readout unit
        // either and its denominator stays the bytes it actually moved. One
        // request per representation is the whole of that, and it is true in
        // every ordering — where the readout is not: two operations run at once
        // here, and which of their terminals the shared reporter publishes is
        // decided by the order they end in. `ClipboardTransferOperationTests`
        // owns what a declared unit does to the bar.
        let expectedIDs = [
            inboundTransferID(generation: 7, repIndex: 0),
            inboundTransferID(generation: 7, repIndex: 1),
        ].sorted()
        #expect(responder.requests.map(\.transferID).sorted() == expectedIDs)
        #expect(service.clipboardContent.text == text)

        // Serving rep 1 again adds no request either — the cache the preview
        // read is the same one a later paste reads.
        let again = await offCooperativePool {
            service.serveData(generation: 7, repIndex: 1, uti: "public.rtf")
        }
        #expect(again == rtf)
        #expect(responder.requests.count == 2)
    }

    @Test("a transfer that finishes before the reveal delay never shows progress")
    func transferBelowRevealDelayNeverShows() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A reveal delay long enough that the fast transfer completes first.
        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, progressRevealDelay: 3600,
            progressIdleGap: 0)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(service: service, guest: guest)
        let text = "small"
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.start()
        defer { responder.cancel() }

        try guest.send(makeTextOfferFrame(generation: 9, text: text))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }

        await service.materializeForPreview()
        #expect(service.clipboardContent.text == text)  // the transfer completed
        #expect(reports.snapshot == nil)  // but it never crossed the reveal delay
    }

    @Test("stop() clears an in-flight readout")
    func stopClearsTransferProgress() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let reports = ClipboardTransferReports()
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", reporter: reports.reporter, progressRevealDelay: 0,
            progressIdleGap: 0)
        service.start()

        let responder = FakeGuestResponder(service: service, guest: guest)
        let text = String(repeating: "S", count: 120 * 1024)  // past one socket buffer
        responder.register(
            generation: 3, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.holdTrailer = true
        responder.start()
        defer { responder.cancel() }

        try guest.send(makeTextOfferFrame(generation: 3, text: text))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }
        let previewTask = Task { await service.materializeForPreview() }
        try await reports.wait { reports.snapshot != nil }

        service.stop()
        try await reports.wait { reports.snapshot == nil }

        responder.releaseTrailer()
        await previewTask.value
    }
}

// MARK: - The guest's end of a parked data connection

/// The transfers whose data connection the receiver closed while the guest's
/// reply was parked.
///
/// A receiver cancels by closing its end and says nothing on the control
/// channel, so this is what a cancellation looks like from the other end: the
/// stream ends where the payload should have been.
private final class HostClosedTransfers: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UInt64] = []

    /// Fires as each closed connection is recorded.
    let recorded = AsyncGate()

    /// The ids recorded so far, in the order their connections ended.
    var all: [UInt64] { lock.withLock { ids } }

    /// Records `transferID` and wakes whatever awaits ``recorded``.
    func record(_ transferID: UInt64) {
        lock.withLock { ids.append(transferID) }
        recorded.notify()
    }
}

/// One transfer's data connection, held open past the point its stream stopped
/// short, so a test can finish it — or watch the receiver close it.
///
/// Every touch of the descriptor runs on one serial queue, so a resumed write
/// can never overlap the close. The watcher thread only reads, which ends when
/// the receiver closes its end, and a descriptor is closed exactly once.
///
/// ``abandon()`` is the one caller off that queue, so it and the close share
/// `lock`: a `shutdown(2)` decided outside the critical section the descriptor
/// is closed in lands on whatever the kernel has since handed that number to —
/// another case's live socket in the same test host. `ClipboardTransferReceiver`
/// holds its own lock across `cancel()` for that hazard.
private final class ParkedDataConnection: @unchecked Sendable {
    private let fd: Int32
    private let transferID: UInt64
    private let closed: HostClosedTransfers
    private let remainder: @Sendable (Int32) -> Void
    private let io: DispatchQueue
    private let lock = NSLock()
    private var isResumed = false
    private var isAbandoned = false
    private var isEnded = false

    /// Opens the connection by writing `prefix`, and keeps `remainder` — the
    /// rest of the stream — for ``resume()``.
    fileprivate init(
        fd: Int32, transferID: UInt64, closed: HostClosedTransfers,
        prefix: @escaping @Sendable (Int32) -> Void,
        remainder: @escaping @Sendable (Int32) -> Void
    ) {
        self.fd = fd
        self.transferID = transferID
        self.closed = closed
        self.remainder = remainder
        io = DispatchQueue(label: "test.clipboard.parked-transfer.\(transferID)")
        io.async { prefix(fd) }
        // A blocking read for as long as the case needs, so it gets a thread of
        // its own rather than one of GCD's global queue's.
        Thread.detachNewThread { [self] in
            _ = try? readToEnd(fd: fd)
            io.async { [self] in end() }
        }
    }

    /// Writes what the hold left unwritten and half-closes, so the receiver
    /// reads the end of the stream and the transfer resolves.
    func resume() {
        lock.withLock { isResumed = true }
        io.async { [self] in
            guard !lock.withLock({ isEnded }) else { return }
            remainder(fd)
            _ = shutdown(fd, SHUT_WR)
        }
    }

    /// Wakes the watcher at teardown, so a connection nothing resolved is closed
    /// rather than left parked — and is not read as a cancellation.
    func abandon() {
        lock.withLock {
            isAbandoned = true
            guard !isEnded else { return }
            ClipboardDataConnection.interrupt(fd: fd)
        }
    }

    /// Closes the descriptor once the receiver's end is gone, recording the
    /// cancellation when nothing had resumed the stream.
    private func end() {
        let (resumed, abandoned) = lock.withLock { () -> (Bool, Bool) in
            isEnded = true
            ClipboardDataConnection.end(fd: fd)
            return (isResumed, isAbandoned)
        }
        if !resumed, !abandoned { closed.record(transferID) }
    }
}

extension [CopyToMacItem] {
    /// The eagerly-resolved representations, for assertions that previously read
    /// `materializeForCopy().representations`.
    fileprivate var resolvedReps: [ClipboardContent.Representation] {
        compactMap {
            switch $0 {
            case .resolved(let rep): rep
            default: nil
            }
        }
    }

    /// The reps promised by offer coordinates, in offer order.
    fileprivate var promised: [CopyToMacPromise] {
        compactMap {
            switch $0 {
            case .promised(let promise): promise
            default: nil
            }
        }
    }

    /// The reasons file payloads were dropped, for asserting the user-facing
    /// message routing.
    fileprivate var droppedReasons: [CopyToMacDropReason] {
        compactMap {
            switch $0 {
            case .droppedFile(let reason): reason
            default: nil
            }
        }
    }
}
