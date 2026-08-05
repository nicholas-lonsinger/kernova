import AppKit
import Testing
import Foundation
import Darwin
import CryptoKit
import KernovaKit
import KernovaTestSupport
import UniformTypeIdentifiers
@testable import Kernova

@Suite("VsockClipboardService")
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

    /// MainActor-isolated buffer fed by a single iterator on the channel.
    ///
    /// Tests that need both "expect frame" and "expect no frame" assertions
    /// against the same channel must not hand-roll iterators per call —
    /// `AsyncThrowingStream` is single-consumer and cancelling an iterator
    /// terminates the shared iteration, poisoning subsequent reads.
    @MainActor
    private final class FrameRecorder {
        var frames: [Frame] = []
        private var consumeTask: Task<Void, Never>?

        /// Fires on every recorded frame; await it instead of polling `frames`.
        let recorded = AsyncGate()

        init(channel: VsockChannel) {
            consumeTask = Task { @MainActor [weak self] in
                do {
                    for try await frame in channel.incoming {
                        self?.frames.append(frame)
                        self?.recorded.notify()
                    }
                } catch {
                    // Stream errored — recording stops. Tests that care
                    // about errors can inspect `frames` and infer.
                }
            }
        }

        func cancel() { consumeTask?.cancel() }
        deinit { consumeTask?.cancel() }

        /// Every recorded `ClipboardChunk` for `transferID`, in arrival order.
        func chunks(for transferID: UInt64) -> [Kernova_V1_ClipboardChunk] {
            frames.compactMap {
                if case .clipboardChunk(let chunk) = $0.payload, chunk.transferID == transferID {
                    return chunk
                }
                return nil
            }
        }

        /// The first recorded frame matching `predicate`, if any.
        func first(where predicate: (Frame) -> Bool) -> Frame? {
            frames.first(where: predicate)
        }
    }

    /// Awaits the recorder's gate (fired per frame) until the recorded frame
    /// count reaches `expected`.
    ///
    /// The gate's stuck-stream backstop bounds the wait.
    private func waitForFrameCount(
        _ recorder: FrameRecorder,
        reaches expected: Int
    ) async throws {
        // `>=` (matching `waitForRecords`): a burst of frames could skip past
        // an `==` check between observations and hang the wait to its backstop;
        // callers assert the exact frame content/count separately.
        try await recorder.recorded.wait {
            recorder.frames.count >= expected
        }
    }

    /// Awaits the recorder's gate until `predicate` holds — used when the exact
    /// frame count is unknown (a multi-chunk transfer's chunk count varies).
    private func waitForFrames(
        _ recorder: FrameRecorder,
        until predicate: @escaping () -> Bool
    ) async throws {
        try await recorder.recorded.wait(until: predicate)
    }

    /// Sleeps `duration` then asserts no frames arrived since `before`.
    ///
    /// Used in suppression tests where we want to prove a `grabIfChanged()`
    /// call produced *no* wire traffic, not just "fewer than the next two".
    private func expectNoNewFrames(
        on recorder: FrameRecorder,
        sinceCount before: Int,
        for duration: Duration = .milliseconds(100)
    ) async throws {
        try await Task.sleep(for: duration)
        if recorder.frames.count != before {
            let extras = Array(recorder.frames[before...])
            Issue.record(
                "Expected no new frames over \(duration); got \(extras.count): \(extras.map { String(describing: $0.payload) })"
            )
        }
    }

    // MARK: - Frame factories

    /// Metadata-only offer carrying one `ClipboardRepresentationInfo` per
    /// representation — the streaming protocol's announce frame.
    private func makeOffer(
        generation: UInt64,
        reps: [(uti: String, byteCount: Int, filename: String, isInline: Bool)],
        isConcealed: Bool = false
    ) -> Frame {
        makeRawOffer(
            generation: generation,
            reps: reps.map {
                (
                    uti: $0.uti, byteCount: UInt64($0.byteCount), filename: $0.filename,
                    isInline: $0.isInline
                )
            },
            isConcealed: isConcealed)
    }

    /// `makeOffer` taking the wire's own `UInt64` byte counts — for the declared
    /// sizes no real payload could have, where the exact value is the point.
    private func makeRawOffer(
        generation: UInt64,
        reps: [(uti: String, byteCount: UInt64, filename: String, isInline: Bool)],
        isConcealed: Bool = false
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.isConcealed = isConcealed
            $0.repInfo = reps.map { rep in
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = rep.uti
                    $0.byteCount = rep.byteCount
                    $0.filename = rep.filename
                    $0.isInline = rep.isInline
                }
            }
        }
        return frame
    }

    /// An offer whose reps are all directories — `is_directory` set, each
    /// declaring the producer's stat-walk estimate (0 for a tree carrying no
    /// file bytes).
    private func makeDirectoryOffer(
        generation: UInt64, reps: [(uti: String, byteCount: UInt64, filename: String)]
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = reps.map { rep in
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = rep.uti
                    $0.byteCount = rep.byteCount
                    $0.filename = rep.filename
                    $0.isInline = false
                    $0.isDirectory = true
                }
            }
        }
        return frame
    }

    /// Convenience for the common single inline-text representation.
    private func makeTextOffer(generation: UInt64, text: String) -> Frame {
        makeOffer(
            generation: generation,
            reps: [(uti: ClipboardContent.utf8TextUTI, byteCount: Data(text.utf8).count, filename: "", isInline: true)]
        )
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
    /// use it so a driven `Begin` matches the service's pending set and
    /// `req.transferID`.
    private func inboundTransferID(generation: UInt64, repIndex: UInt64) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: Int(repIndex), hostMinted: true)
    }

    /// A `ClipboardRequest` pulling representation `repIndex` of `generation`.
    private func makeRequest(generation: UInt64, repIndex: UInt64, uti: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.transferID = transferID(generation: generation, repIndex: repIndex)
            $0.uti = uti
            $0.maxAcceptByteCount = .max  // no ceiling
        }
        return frame
    }

    // MARK: - Streaming a reply to the service (we are the sender)

    /// Streams `ClipboardChunk`(s) → `ClipboardStreamEnd` for `transferID` from
    /// the guest end, **without** a preceding `Begin`.
    ///
    /// Used to complete a transfer whose `Begin` the responder already sent
    /// (`beginOnly`), so a host pull parked on it resolves with the bytes.
    private func sendChunkAndEnd(
        from guest: VsockChannel,
        transferID: UInt64,
        bytes: Data,
        chunkSize: Int = 64 * 1024
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            var chunkFrame = Frame()
            chunkFrame.protocolVersion = 1
            chunkFrame.clipboardChunk = Kernova_V1_ClipboardChunk.with {
                $0.transferID = transferID
                $0.offset = UInt64(offset)
                $0.data = bytes.subdata(in: offset..<end)
            }
            try guest.send(chunkFrame)
            offset = end
        }
        var endFrame = Frame()
        endFrame.protocolVersion = 1
        endFrame.clipboardStreamEnd = Kernova_V1_ClipboardStreamEnd.with {
            $0.transferID = transferID
            $0.totalBytes = UInt64(bytes.count)
            $0.sha256 = Data(SHA256.hash(data: bytes))
        }
        try guest.send(endFrame)
    }

    /// Acknowledges the service's outbound transfer so its sender (which waits
    /// for the first ack before chunking) makes progress.
    ///
    /// A single ack
    /// advertising a window large enough for the whole payload drains it.
    private func sendAck(
        from guest: VsockChannel,
        transferID: UInt64,
        bytesConsumed: UInt64,
        windowBytes: UInt64
    ) throws {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAck = Kernova_V1_ClipboardStreamAck.with {
            $0.transferID = transferID
            $0.bytesConsumed = bytesConsumed
            $0.windowBytes = windowBytes
        }
        try guest.send(frame)
    }

    /// Reassembles the chunks of one outbound transfer into a single buffer,
    /// validating contiguity along the way.
    private func reassemble(_ chunks: [Kernova_V1_ClipboardChunk]) -> Data {
        var result = Data()
        for chunk in chunks.sorted(by: { $0.offset < $1.offset }) {
            result.append(chunk.data)
        }
        return result
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // The clipboard listener accepts the connection before the service is
        // constructed, so connectivity is equivalent to "started and not yet
        // stopped". Liveness lives on the control channel.
        #expect(service.isConnected)
    }

    @Test("A control-plane payload on the clipboard channel closes it")
    func wrongPortPayloadClosesChannel() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Hello belongs on the control channel — on the clipboard channel it is
        // a protocol violation the service answers by dropping the channel (#145).
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with { $0.serviceVersion = 1 }
        try guest.send(hello)

        // The service closes its end; the guest observes EOF.
        await expectEOF(on: guest)
    }

    @Test("A payload-less frame is dropped without closing the clipboard channel")
    func payloadLessFrameIsDropped() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        var empty = Frame()
        empty.protocolVersion = 1
        try guest.send(empty)

        // A subsequent offer still lands — proof the empty frame was dropped
        // benignly rather than treated as a wrong-port violation.
        try guest.send(makeTextOffer(generation: 1, text: "still alive"))
        try await waitForChange { !service.clipboardContent.isEmpty }
    }

    // MARK: - Outbound (we grab; the service offers and streams)

    @Test("grabIfChanged sends a metadata-only offer describing each representation")
    func grabSendsOfferWithRepInfo() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

    @Test("grabIfChanged uses a monotonically increasing generation")
    func grabUsesMonotonicGeneration() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "first")
        service.grabIfChanged()
        let firstOffer = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offerA) = firstOffer.payload else {
            Issue.record("Expected first clipboardOffer, got \(String(describing: firstOffer.payload))")
            return
        }

        service.clipboardContent = ClipboardContent(text: "second")
        service.grabIfChanged()
        let secondOffer = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offerB) = secondOffer.payload else {
            Issue.record("Expected second clipboardOffer, got \(String(describing: secondOffer.payload))")
            return
        }
        #expect(offerB.generation > offerA.generation)
    }

    @Test("A request for an offered rep streams Begin → Chunk(s) → End that reassemble to the bytes")
    func requestStreamsBackTheRepresentation() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let text = "payload to stream"
        let expectedBytes = Data(text.utf8)
        service.clipboardContent = ClipboardContent(text: text)
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        let xid = transferID(generation: offer.generation, repIndex: 0)

        // Record outbound frames so we can collect Begin + every Chunk + End.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))

        // Begin arrives first; ack it so the sender starts chunking, advertising
        // a window comfortably larger than the payload.
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } != nil
        }
        let beginFrame = try #require(
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            })
        guard case .clipboardStreamBegin(let begin) = beginFrame.payload else {
            Issue.record("Expected clipboardStreamBegin")
            return
        }
        #expect(begin.transferID == xid)
        #expect(begin.uti == ClipboardContent.utf8TextUTI)
        #expect(begin.totalBytes == UInt64(expectedBytes.count))
        #expect(begin.isInline)

        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 512 * 1024)

        // Wait for End, then reassemble the recorded chunks.
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamEnd = $0.payload { return true }; return false
            } != nil
        }
        let endFrame = try #require(
            recorder.first {
                if case .clipboardStreamEnd = $0.payload { return true }; return false
            })
        guard case .clipboardStreamEnd(let end) = endFrame.payload else {
            Issue.record("Expected clipboardStreamEnd")
            return
        }
        #expect(end.transferID == xid)
        #expect(end.totalBytes == UInt64(expectedBytes.count))

        let reassembled = reassemble(recorder.chunks(for: xid))
        #expect(reassembled == expectedBytes)
        // The End digest must match a fresh hash of the reassembled bytes.
        #expect(end.sha256 == Data(SHA256.hash(data: expectedBytes)))
    }

    @Test(
        "An offered folder is estimate-only until requested, then archived at request time and streamed as a valid archive"
    )
    func requestArchivesFolderAtRequestTime() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // The request triggers the off-main request-time archive, then the
        // stream of the resulting `.aar`.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } != nil
        }
        let beginFrame = try #require(
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            })
        guard case .clipboardStreamBegin(let begin) = beginFrame.payload else {
            Issue.record("Expected clipboardStreamBegin")
            return
        }
        #expect(begin.transferID == xid)
        #expect(!begin.isInline)
        #expect(begin.filename == "Project")

        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 512 * 1024)
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamEnd = $0.payload { return true }; return false
            } != nil
        }
        let reassembled = reassemble(recorder.chunks(for: xid))
        // The Begin carries the archive's wire-exact size, superseding the
        // offer's estimate.
        #expect(begin.totalBytes == UInt64(reassembled.count))

        // The streamed bytes are an `.aar` that extracts back to the tree.
        let aarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: aarDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aarDir) }
        let aar = aarDir.appendingPathComponent("got.aar")
        try reassembled.write(to: aar)
        let dest = aarDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try ClipboardDirectoryArchive.extract(archiveAt: aar, to: dest)
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // The zero estimate gates nothing: each rep archives at request time and
        // the streamed `.aar` rebuilds its tree.
        let emptyOut = try await pullAndExtractArchive(
            generation: offer.generation, repIndex: 0, uti: offer.repInfo[0].uti, from: guest,
            recorder: recorder)
        defer { try? FileManager.default.removeItem(at: emptyOut.deletingLastPathComponent()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyOut.path).isEmpty)

        let scaffoldOut = try await pullAndExtractArchive(
            generation: offer.generation, repIndex: 1, uti: offer.repInfo[1].uti, from: guest,
            recorder: recorder)
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

    /// Requests representation `repIndex` of `generation`, waits out its stream,
    /// and extracts the reassembled `.aar` into a fresh directory it returns.
    private func pullAndExtractArchive(
        generation: UInt64, repIndex: UInt64, uti: String, from guest: VsockChannel,
        recorder: FrameRecorder
    ) async throws -> URL {
        let xid = transferID(generation: generation, repIndex: repIndex)
        try guest.send(makeRequest(generation: generation, repIndex: repIndex, uti: uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin(let begin) = $0.payload {
                    return begin.transferID == xid
                }
                return false
            } != nil
        }
        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 512 * 1024)
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamEnd(let end) = $0.payload { return end.transferID == xid }
                return false
            } != nil
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let aar = scratch.appendingPathComponent("got.aar")
        try reassemble(recorder.chunks(for: xid)).write(to: aar)
        try ClipboardDirectoryArchive.extract(archiveAt: aar, to: dest)
        return dest
    }

    @Test("A large outbound payload streams as multiple chunks that reassemble exactly")
    func largeOutboundStreamsMultipleChunks() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // > 64 KiB default chunk so the sender emits several chunks.
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

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } != nil
        }
        // A window covering the whole payload lets every chunk flow after one ack.
        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: UInt64(bytes.count))

        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamEnd = $0.payload { return true }; return false
            } != nil
        }
        let chunks = recorder.chunks(for: xid)
        #expect(chunks.count > 1, "Expected a multi-chunk transfer for a 200 KiB payload")
        #expect(reassemble(chunks) == bytes)
    }

    @Test("grabIfChanged is suppressed when content is unchanged or empty")
    func grabSuppressionGuards() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Empty content → no offer.
        var snapshot = recorder.frames.count
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: snapshot)

        // First non-empty content → exactly one offer.
        service.clipboardContent = ClipboardContent(text: "alpha")
        service.grabIfChanged()
        try await waitForFrameCount(recorder, reaches: snapshot + 1)
        guard case .clipboardOffer = recorder.frames[snapshot].payload else {
            Issue.record(
                "Expected clipboardOffer for 'alpha', got \(String(describing: recorder.frames[snapshot].payload))")
            return
        }
        snapshot = recorder.frames.count

        // Same content → no second offer.
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: snapshot)

        // Fresh content → another offer.
        service.clipboardContent = ClipboardContent(text: "beta")
        service.grabIfChanged()
        try await waitForFrameCount(recorder, reaches: snapshot + 1)
        guard case .clipboardOffer = recorder.frames[snapshot].payload else {
            Issue.record(
                "Expected clipboardOffer for 'beta', got \(String(describing: recorder.frames[snapshot].payload))")
            return
        }
    }

    // MARK: - Outbound request edge cases

    @Test("Stale ClipboardRequest (wrong generation) is rejected with an Abort — no stream begins")
    func staleRequestRejectedWithAbort() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "payload")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected offer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        let xid = transferID(generation: offer.generation, repIndex: 0)

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Request a generation that doesn't match the pending offer. Instead of
        // dropping it silently (the pre-#357 behavior, which parked the guest's
        // pull to its 120 s backstop), the service Aborts it so the requester
        // wakes immediately.
        let staleXID = transferID(generation: offer.generation &+ 1_000, repIndex: 0)
        var staleRequest = makeRequest(generation: offer.generation &+ 1_000, repIndex: 0, uti: info.uti)
        // Keep the transferID consistent with the stale generation so nothing matches.
        staleRequest.clipboardRequest.transferID = staleXID
        try guest.send(staleRequest)

        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == staleXID
                }
                return false
            } != nil
        }
        let abortFrame = try #require(
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == staleXID
                }
                return false
            })
        guard case .clipboardStreamAbort(let abort) = abortFrame.payload else {
            Issue.record("Expected clipboardStreamAbort")
            return
        }
        #expect(abort.code == "request.stale")
        // No Begin is ever sent for the stale request.
        #expect(
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } == nil)

        // A valid request still streams — the channel wasn't poisoned.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin(let begin) = $0.payload { return begin.transferID == xid }
                return false
            } != nil
        }
    }

    @Test("A request whose rep index is out of range is rejected with an Abort")
    func outOfRangeRequestRejectedWithAbort() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "payload")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected offer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // rep index 5 is past the single offered rep — the range guard fires
        // before the UTI check, so the abort carries `request.range`.
        let outOfRangeXID = transferID(generation: offer.generation, repIndex: 5)
        try guest.send(makeRequest(generation: offer.generation, repIndex: 5, uti: info.uti))

        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == outOfRangeXID
                }
                return false
            } != nil
        }
        let abortFrame = try #require(
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == outOfRangeXID
                }
                return false
            })
        guard case .clipboardStreamAbort(let abort) = abortFrame.payload else {
            Issue.record("Expected clipboardStreamAbort")
            return
        }
        #expect(abort.code == "request.range")
        #expect(
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } == nil)
    }

    @Test("A request whose uti doesn't match the offered rep is rejected with an Abort")
    func mismatchedUTIRequestRejectedWithAbort() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "payload")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected offer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        let xid = transferID(generation: offer.generation, repIndex: 0)

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Wrong uti for rep 0 → rejected with an Abort.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: "public.bogus"))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == xid
                }
                return false
            } != nil
        }
        let abortFrame = try #require(
            recorder.first {
                if case .clipboardStreamAbort(let abort) = $0.payload {
                    return abort.transferID == xid
                }
                return false
            })
        guard case .clipboardStreamAbort(let abort) = abortFrame.payload else {
            Issue.record("Expected clipboardStreamAbort")
            return
        }
        #expect(abort.code == "request.uti")
        // No Begin is ever sent for the mismatched request (catches a dropped
        // `return` that would Abort *and* start the transfer). Asserted before
        // the valid request below, whose Begin shares this xid.
        #expect(
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
            } == nil)

        // The correct request still works, proving the channel wasn't poisoned.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin(let begin) = $0.payload { return begin.transferID == xid }
                return false
            } != nil
        }
    }

    @Test("handleRequest send failure is handled gracefully and leaves the service connected")
    func requestSendFailureIsHandledGracefully() async throws {
        let (hostFd, _, host, guest) = try makeRawPair()
        host.start()
        guest.start()

        // SO_NOSIGPIPE on the host channel's fd so a write to a peer-closed
        // socket surfaces as an error rather than delivering SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(hostFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

        // Queue the request, then close the guest end so the service's stream
        // frames arrive at a dead peer.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
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
    /// For every `ClipboardRequest` the host sends, it streams back the bytes
    /// registered for that `(generation, repIndex)`. Lets a test drive
    /// `materializeForPreview()` / `materializeForCopy()` — which block on the
    /// host's pull continuations — without hand-sequencing each request.
    ///
    /// Reps are keyed by `(generation, repIndex)`; the responder mints the host
    /// transfer id [H3] itself so the test only supplies the payload. Requests
    /// for an unregistered rep are ignored (the host's continuation stays parked
    /// until the test tears down or supersedes).
    @MainActor
    private final class FakeGuestResponder {
        struct Reply {
            let uti: String
            let bytes: Data
            let filename: String
            let isInline: Bool
            /// When `true`, only `Begin` is streamed — no chunks, no `End`.
            ///
            /// Used to create a live receiver-side transfer that a later
            /// supersession/release can cancel while the host's pull is parked.
            let beginOnly: Bool
        }

        private let guest: VsockChannel
        private var replies: [UInt64: Reply] = [:]
        private var consumeTask: Task<Void, Never>?

        /// Fires after each request is answered; await it to observe progress.
        let answered = AsyncGate()
        /// Every `ClipboardRequest` the host sent, in arrival order.
        private(set) var requests: [Kernova_V1_ClipboardRequest] = []

        /// When `true`, the stream sends Begin + all chunks but parks before `End`
        /// until `releaseEnd()` — so a test can observe a live, mid-flight transfer
        /// (the host has received bytes but the pull hasn't resolved).
        var holdEnd = false
        private let endGate = AsyncGate()
        private var endReleased = false

        /// Releases a stream parked by `holdEnd` so it sends its `End`.
        func releaseEnd() {
            endReleased = true
            endGate.notify()
        }

        init(guest: VsockChannel) {
            self.guest = guest
        }

        /// Registers the payload to stream when the host requests
        /// `(generation, repIndex)`.
        func register(
            generation: UInt64, repIndex: UInt64, uti: String, bytes: Data,
            filename: String = "", isInline: Bool, beginOnly: Bool = false
        ) {
            let xid = ClipboardTransferID.make(
                generation: generation, repIndex: Int(repIndex), hostMinted: true)
            replies[xid] = Reply(
                uti: uti, bytes: bytes, filename: filename, isInline: isInline, beginOnly: beginOnly)
        }

        /// Starts draining the channel and answering requests.
        ///
        /// The closure runs off-actor on the channel iterator but hops back to
        /// `@MainActor` to touch `replies`/`requests`, matching this suite's
        /// isolation.
        func start() {
            consumeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await frame in self.guest.incoming {
                        guard case .clipboardRequest(let req) = frame.payload else { continue }
                        self.requests.append(req)
                        if let reply = self.replies[req.transferID] {
                            try await self.stream(req: req, reply: reply)
                        }
                        self.answered.notify()
                    }
                } catch {
                    // Channel closed — stop answering.
                }
            }
        }

        func cancel() { consumeTask?.cancel() }
        deinit { consumeTask?.cancel() }

        /// Streams Begin → Chunk(s) → End for one request's registered reply.
        private func stream(req: Kernova_V1_ClipboardRequest, reply: Reply) async throws {
            var begin = Frame()
            begin.protocolVersion = 1
            begin.clipboardStreamBegin = Kernova_V1_ClipboardStreamBegin.with {
                $0.generation = req.generation
                $0.transferID = req.transferID
                $0.uti = reply.uti
                $0.totalBytes = UInt64(reply.bytes.count)
                $0.filename = reply.filename
                $0.isInline = reply.isInline
            }
            try guest.send(begin)
            // Begin-only: leave the transfer live so a supersede/release can
            // cancel it; never send chunks or End.
            if reply.beginOnly { return }

            var offset = 0
            let chunkSize = 64 * 1024
            while offset < reply.bytes.count {
                let end = min(offset + chunkSize, reply.bytes.count)
                var chunkFrame = Frame()
                chunkFrame.protocolVersion = 1
                chunkFrame.clipboardChunk = Kernova_V1_ClipboardChunk.with {
                    $0.transferID = req.transferID
                    $0.offset = UInt64(offset)
                    $0.data = reply.bytes.subdata(in: offset..<end)
                }
                try guest.send(chunkFrame)
                offset = end
            }

            // Park before End so a test can observe the live, mid-flight transfer.
            if holdEnd { try await endGate.wait { self.endReleased } }

            var endFrame = Frame()
            endFrame.protocolVersion = 1
            endFrame.clipboardStreamEnd = Kernova_V1_ClipboardStreamEnd.with {
                $0.transferID = req.transferID
                $0.totalBytes = UInt64(reply.bytes.count)
                $0.sha256 = Data(SHA256.hash(data: reply.bytes))
            }
            try guest.send(endFrame)
        }
    }

    @Test("An offer publishes metadata-only .pendingRemote placeholders and sends no request")
    func offerPublishesPlaceholdersWithoutRequesting() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Record outbound frames so we can prove the offer drew no request.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        let textBytes = Data("hi".utf8)
        let fileBytes = 4_000
        try guest.send(
            makeOffer(
                generation: 7,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: textBytes.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: fileBytes, filename: "doc.bin", isInline: false),
                ]))

        try await waitForChange { service.clipboardContent.representations.count == 2 }
        let reps = service.clipboardContent.representations
        // Both reps are placeholders, in the guest's offer order.
        #expect(reps.allSatisfy { $0.isPendingRemote })
        #expect(reps.map(\.uti) == [ClipboardContent.utf8TextUTI, "public.data"])
        #expect(reps.map(\.byteCount) == [textBytes.count, fileBytes])
        #expect(reps.map(\.filename) == ["", "doc.bin"])

        // No ClipboardRequest is sent at offer time — pulling is lazy.
        try await expectNoNewFrames(on: recorder, sinceCount: 0, for: .milliseconds(150))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // A v99 offer must be dropped; if the version check is missing the
        // service would publish a gen=1 placeholder.
        var offerV99 = makeTextOffer(generation: 1, text: "ignored")
        offerV99.protocolVersion = 99
        try guest.send(offerV99)

        // A valid v1 offer for a different generation. Its placeholder must be
        // the one published — proof that the v99 offer was dropped.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.png", byteCount: 99, filename: "kept.png", isInline: false)]))

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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        let text = "from guest"
        let bytes = Data(text.utf8)
        responder.register(
            generation: 42, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: bytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 42,
                reps: [(uti: ClipboardContent.utf8TextUTI, byteCount: bytes.count, filename: "", isInline: true)]))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        let bytes = Data("rtfd-with-inline-image".utf8)
        responder.register(
            generation: 53, repIndex: 0, uti: UTType.flatRTFD.identifier, bytes: bytes,
            isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 53,
                reps: [(uti: UTType.flatRTFD.identifier, byteCount: bytes.count, filename: "", isInline: true)]))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
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
            makeOffer(
                generation: 11,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: text.utf8.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: 4096, filename: "doc.bin", isInline: false),
                    (uti: "public.png", byteCount: oversizeImage, filename: "", isInline: true),
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 4, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("x".utf8),
            isInline: true)
        responder.start()

        try guest.send(makeTextOffer(generation: 4, text: "x"))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 7, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("hunter2".utf8), isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 7,
                reps: [
                    (
                        uti: ClipboardContent.utf8TextUTI, byteCount: Data("hunter2".utf8).count,
                        filename: "", isInline: true
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

    @Test("A large multi-chunk inline preview rep reassembles correctly")
    func previewLargeInlineReassembles() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // > 64 KiB inline text so the responder emits several chunks; still well
        // under maxEditableTextBytes so preview pulls it.
        let bytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 53 &+ 7) })
        let textUTI = ClipboardContent.utf8TextUTI

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(generation: 3, repIndex: 0, uti: textUTI, bytes: bytes, isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 3,
                reps: [(uti: textUTI, byteCount: bytes.count, filename: "", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()
        #expect(service.clipboardContent.representations.first?.inMemoryData == bytes)
    }

    @Test("materializeForCopy promises every rep from metadata — nothing crosses at the click")
    func copyMaterializesEveryRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("inline payload".utf8)
        let fileBytes = Data((0..<(150 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 9, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "from-guest.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 9,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: inlineBytes.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: fileBytes.count, filename: "from-guest.bin", isInline: false),
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
        // through `copyToMacData`, the file's `.fileURL` through
        // `copyToMacFileURL` — both off the main thread here.
        let inlineData = await offCooperativePool {
            service.copyToMacData(
                generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(inlineData == inlineBytes)
        let fileURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 9, repIndex: 1)
        }
        #expect(try Data(contentsOf: #require(fileURL)) == fileBytes)
        #expect(responder.requests.count == 2)
    }

    @Test("a promised directory rep extracts into a real folder at paste time")
    func copyReTagsDirectoryRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // The bytes the "guest" streams are an `.aar` of a small tree.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("MyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let aarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: aarDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aarDir) }
        let aar = aarDir.appendingPathComponent("MyFolder.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: src, to: aar)
        let aarBytes = try Data(contentsOf: aar)

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 11, repIndex: 0, uti: UTType.folder.identifier, bytes: aarBytes,
            filename: "MyFolder", isInline: false)
        responder.start()

        // The offer carries the directory flag; the offer-agnostic stream layer
        // does not, so the service must re-tag the delivered rep from it.
        try guest.send(
            makeDirectoryOffer(
                generation: 11,
                reps: [
                    (
                        uti: UTType.folder.identifier, byteCount: UInt64(aarBytes.count),
                        filename: "MyFolder"
                    )
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // The click promises the directory rep like any other — no pull, no
        // archive traffic.
        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0])
        #expect(items.promised.first?.filename == "MyFolder")
        #expect(responder.requests.isEmpty)

        // The paste-time `.fileURL` fire pulls the streamed `.aar` and extracts it
        // into a real folder, so a Finder paste recreates the tree.
        let url = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 11, repIndex: 0) })
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(url.lastPathComponent == "MyFolder")
        #expect(
            try String(contentsOf: url.appendingPathComponent("f.txt"), encoding: .utf8) == "x")
    }

    @Test("a directory rep offered at 0 bytes is promised and pastes as a real tree")
    func copyPromisesByteFreeDirectoryReps() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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
        let emptyAAR = src.appendingPathComponent("Empty.aar")
        let scaffoldAAR = src.appendingPathComponent("Scaffold.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: empty, to: emptyAAR)
        try ClipboardDirectoryArchive.archive(directoryAt: scaffold, to: scaffoldAAR)

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 12, repIndex: 0, uti: UTType.folder.identifier,
            bytes: try Data(contentsOf: emptyAAR), filename: "Empty", isInline: false)
        responder.register(
            generation: 12, repIndex: 1, uti: UTType.folder.identifier,
            bytes: try Data(contentsOf: scaffoldAAR), filename: "Scaffold", isInline: false)
        responder.start()

        // The estimate is 0 for both, which is what the wire carries — neither rep
        // may be mistaken for an empty payload and filtered away.
        try guest.send(
            makeDirectoryOffer(
                generation: 12,
                reps: [
                    (uti: UTType.folder.identifier, byteCount: 0, filename: "Empty"),
                    (uti: UTType.folder.identifier, byteCount: 0, filename: "Scaffold"),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }
        #expect(service.clipboardContent.representations.map(\.isPendingRemote) == [true, true])

        let items = service.materializeForCopy()
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.filename) == ["Empty", "Scaffold"])
        #expect(responder.requests.isEmpty)

        let emptyURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 12, repIndex: 0) })
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: emptyURL.path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(emptyURL.lastPathComponent == "Empty")
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyURL.path).isEmpty)

        let scaffoldURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 12, repIndex: 1) })
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("preview me".utf8)
        let fileBytes = Data((0..<(80 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 6, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 6, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "doc.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 6,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: inlineBytes.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: fileBytes.count, filename: "doc.bin", isInline: false),
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
            service.copyToMacData(
                generation: 6, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(cachedData == inlineBytes)
        #expect(responder.requests.count == 1)

        // The file rep misses the cache and takes the blocking-pull path — now the
        // second request goes out; nothing was ever double-requested.
        let fileURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 6, repIndex: 1)
        }
        #expect(try Data(contentsOf: #require(fileURL)) == fileBytes)
        #expect(responder.requests.count == 2)
        #expect(Set(responder.requests.map(\.transferID)).count == 2)

        // The blocking pull cached its rep too: a repeat fire re-serves the staged
        // file without a third request.
        let repeatURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 6, repIndex: 1)
        }
        #expect(repeatURL == fileURL)
        #expect(responder.requests.count == 2)
    }

    @Test("after stop(), a fully-materialized file set stays servable")
    func stopKeepsMaterializedRepsServable() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        // The test calls stop() itself mid-flow (that is the action under test);
        // this defer is an idempotent safety net for the early-throw path.
        defer { service.stop() }

        let inlineBytes = Data("keep me".utf8)
        let fileBytes = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 9, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "kept.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 9,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: inlineBytes.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: fileBytes.count, filename: "kept.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Materialize rep 0 through the preview and rep 1 through a paste-time
        // pull — the whole file set is materialized before the stop.
        await service.materializeForPreview()
        let pulledURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 9, repIndex: 1) })
        #expect(try Data(contentsOf: pulledURL) == fileBytes)

        service.stop()

        // The inline cache still serves its bytes...
        let cachedData = await offCooperativePool {
            service.copyToMacData(generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(cachedData == inlineBytes)
        // ...and the staged file behind the vended URL is still on disk.
        let repeatURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 9, repIndex: 1) })
        #expect(repeatURL == pulledURL)
        #expect(try Data(contentsOf: repeatURL) == fileBytes)
        #expect(service.lastTransferIssue == nil)
    }

    @Test("after stop(), a partially-materialized file set serves nothing and raises one issue")
    func stopRefusesPartiallyMaterializedFileSet() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let inlineBytes = Data("still served".utf8)
        let fileBytes = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: inlineBytes,
            isInline: true)
        responder.register(
            generation: 9, repIndex: 1, uti: "public.data", bytes: fileBytes,
            filename: "kept.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 9,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: inlineBytes.count, filename: "", isInline: true),
                    (uti: "public.data", byteCount: fileBytes.count, filename: "kept.bin", isInline: false),
                    (uti: "public.data", byteCount: 512, filename: "never.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        // Materialize rep 0 and rep 1; rep 2 is never pulled, so the file set
        // {kept.bin, never.bin} is only partially materialized at the stop.
        await service.materializeForPreview()
        _ = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 9, repIndex: 1) })

        service.stop()

        // All-or-nothing: with never.bin unreachable, the materialized sibling
        // is refused too — a Finder paste lands no silent partial file set.
        let keptURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 9, repIndex: 1)
        }
        #expect(keptURL == nil)
        let neverURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 9, repIndex: 2)
        }
        #expect(neverURL == nil)

        // One issue for the whole paste, not one per fire.
        let issue = try #require(service.lastTransferIssue)
        guard case .localFailure(let code, _) = issue.kind else {
            Issue.record("Expected a localFailure issue, got \(issue.kind)")
            return
        }
        #expect(code == ClipboardErrorCode.pasteIncompleteSet.rawValue)
        _ = await offCooperativePool { service.copyToMacFileURL(generation: 9, repIndex: 1) }
        #expect(service.lastTransferIssue == issue)

        // Inline flavors keep serving regardless.
        let cachedData = await offCooperativePool {
            service.copyToMacData(generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI)
        }
        #expect(cachedData == inlineBytes)
    }

    @Test("a superseding offer makes the old generation unservable; its staged file rides the grace window")
    func supersedingOfferKeepsOldStagingInGraceWindow() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(48 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 1, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "old.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.data", byteCount: fileBytes.count, filename: "old.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let stagedURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 1, repIndex: 0) })
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // A newer offer supersedes gen=1: its coordinates stop serving, but its
        // staged file rides the maxGenerations grace window so a Finder still
        // copying out the vended URL isn't cut off.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))
        try await waitForChange {
            service.clipboardContent.representations.first?.filename == "new.png"
        }

        // The old coordinates serve nothing — from the cache or the wire...
        let staleURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 1, repIndex: 0)
        }
        #expect(staleURL == nil)
        let staleData = await offCooperativePool {
            service.copyToMacData(generation: 1, repIndex: 0, uti: "public.data")
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(32 * 1024)).map { UInt8(truncatingIfNeeded: $0 &+ 5) })
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 15, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "released.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 15,
                reps: [(uti: "public.data", byteCount: fileBytes.count, filename: "released.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let stagedURL = try #require(
            await offCooperativePool { service.copyToMacFileURL(generation: 15, repIndex: 0) })
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // The guest releases the offer — a supersession: the promise drops, but
        // the staged file rides the grace window.
        var release = Frame()
        release.protocolVersion = 1
        release.clipboardRelease = Kernova_V1_ClipboardRelease.with { $0.generation = 15 }
        try guest.send(release)

        // Barrier: a control frame sent after the release, processed in order on
        // the single channel — once it surfaces, handleRelease has run.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "release processed",
            inReplyTo: "clipboard.release")
        try await waitForChange { service.lastTransferIssue != nil }

        let staleURL = await offCooperativePool {
            service.copyToMacFileURL(generation: 15, repIndex: 0)
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
        let service = VsockClipboardService(
            channel: host, label: label, stagingTempRoot: tempRoot)

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
        try guest.send(makeTextOffer(generation: 1, text: "first"))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(retractionCalls == 1)
        #expect(service.lastTransferIssue == nil)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))

        // Second offer supersedes a promised write still on the pasteboard: the
        // retraction is surfaced and older-session staging is reclaimed.
        try guest.send(makeTextOffer(generation: 2, text: "second"))
        try await waitForChange { service.lastTransferIssue != nil }
        #expect(retractionCalls == 2)
        let issue = try #require(service.lastTransferIssue)
        guard case .staleCopyRetracted = issue.kind else {
            Issue.record("Expected a staleCopyRetracted issue, got \(issue.kind)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test("a ClipboardRelease retracts the stale host write and surfaces the issue")
    func releaseRetractsStaleHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        // Nothing to retract at the offer; the release finds the stale write.
        var retractionResults: [Bool] = [false, true]
        var retractionCalls = 0
        service.retractStaleHostWrite = {
            retractionCalls += 1
            return retractionResults.isEmpty ? false : retractionResults.removeFirst()
        }
        service.start()
        defer { service.stop() }

        try guest.send(makeTextOffer(generation: 4, text: "released"))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(retractionCalls == 1)
        #expect(service.lastTransferIssue == nil)

        var release = Frame()
        release.protocolVersion = 1
        release.clipboardRelease = Kernova_V1_ClipboardRelease.with { $0.generation = 4 }
        try guest.send(release)
        try await waitForChange {
            if case .staleCopyRetracted = service.lastTransferIssue?.kind { return true }
            return false
        }
        #expect(retractionCalls == 2)
    }

    @Test("stop() never retracts the host write — only supersession and release do")
    func stopDoesNotRetractHostWrite() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        var retractionCalls = 0
        service.retractStaleHostWrite = {
            retractionCalls += 1
            return false
        }
        service.start()

        try guest.send(makeTextOffer(generation: 1, text: "hello"))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        service.retractStaleHostWrite = { publisher.retractPromisedWrite() }
        service.start()
        defer { service.stop() }

        // Guest offer gen=1, promised onto the pasteboard by Copy to Mac.
        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.data", byteCount: 128, filename: "a.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        let outcome = await publisher.publish(from: service)
        #expect(outcome.didWrite)
        #expect(pasteboard.pasteboardItems?.isEmpty == false)

        // The guest copies again while the pasteboard still holds our write:
        // the stale promise is retracted and the issue explains.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.data", byteCount: 64, filename: "b.bin", isInline: false)]))
        try await waitForChange { service.lastTransferIssue != nil }
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)

        // Publish gen=2, then the user copies their own content over it: the
        // next supersession must leave the user's pasteboard untouched.
        _ = await publisher.publish(from: service)
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        let countBefore = pasteboard.changeCount
        try guest.send(
            makeOffer(
                generation: 3,
                reps: [(uti: "public.data", byteCount: 32, filename: "c.bin", isInline: false)]))
        try await waitForChange { service.lastTransferIssue == nil }
        #expect(pasteboard.changeCount == countBefore)
        #expect(pasteboard.string(forType: .string) == "mine")
    }

    @Test("a resolved (non-promised) write is never retracted by a later offer")
    func resolvedWriteSurvivesSupersession() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
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
        #expect(outcome.didWrite)
        let countAfterWrite = pasteboard.changeCount

        try guest.send(makeTextOffer(generation: 1, text: "guest"))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }
        #expect(pasteboard.changeCount == countAfterWrite)
        #expect(service.lastTransferIssue == nil)
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
            channel: host1, label: label, stagingTempRoot: tempRoot)
        service1.start()
        let fileBytes = Data((0..<(16 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(guest: guest1)
        defer { responder.cancel() }
        responder.register(
            generation: 1, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "session1.bin", isInline: false)
        responder.start()
        try guest1.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.data", byteCount: fileBytes.count, filename: "session1.bin", isInline: false)]))
        try await waitForChange { service1.clipboardContent.representations.count == 1 }
        let stagedURL = try #require(
            await offCooperativePool { service1.copyToMacFileURL(generation: 1, repIndex: 0) })
        service1.stop()
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        // Session 2, pasteboard still holding the VM's write: the older root
        // keeps backing the vended URL.
        let (guest2, host2) = try makePair()
        guest2.start()
        host2.start()
        defer { guest2.close() }
        let service2 = VsockClipboardService(
            channel: host2, label: label, stagingTempRoot: tempRoot)
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
            channel: host3, label: label, stagingTempRoot: tempRoot)
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        try guest.send(
            makeOffer(
                generation: 12,
                reps: [
                    (uti: "public.data", byteCount: 10, filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: 20, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let responder = FakeGuestResponder(guest: guest)
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        // Two files each under the cap but whose TOTAL exceeds it — the deadline
        // gate is all-or-nothing over the total, so the whole set is refused
        // rather than pasted piecemeal. The inline text rep still promises: only
        // paste-bound (non-inline) reps are budget-gated.
        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafePasteBytes) / 2 + 1
        try guest.send(
            makeOffer(
                generation: 13,
                reps: [
                    (uti: ClipboardContent.utf8TextUTI, byteCount: 12, filename: "", isInline: true),
                    (uti: "public.data", byteCount: Int(half), filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: Int(half), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        let items = service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.promised.map(\.repIndex) == [0])
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        // The advisory is a metadata sum — nothing was pulled to decide it.
        #expect(responder.requests.isEmpty)
        // The refusal is also raised as a transfer issue, the only surface an
        // automatic passthrough publish — which discards the outcome — has.
        #expect(
            service.lastTransferIssue?.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage))
    }

    @Test("a sibling rep pulling fine does not clear the refusal the file set raised")
    func overBudgetRefusalSurvivesASuccessfulSiblingPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let noteBytes = Data("note".utf8)
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 14, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: noteBytes,
            isInline: true)
        responder.start()

        // The shape that erased the refusal: over-cap files alongside a small
        // inline text rep the window previews.
        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafePasteBytes) / 2 + 1
        try guest.send(
            makeOffer(
                generation: 14,
                reps: [
                    (
                        uti: ClipboardContent.utf8TextUTI, byteCount: noteBytes.count, filename: "",
                        isInline: true
                    ),
                    (uti: "public.data", byteCount: Int(half), filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: Int(half), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 3 }

        _ = service.materializeForCopy()
        let refusal = try #require(service.lastTransferIssue)
        #expect(
            refusal.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage))

        // The preview pulls the text rep successfully. That says nothing about
        // the refused file set, which is still the only thing the user must act
        // on — so the refusal stays up rather than being cleared before it renders.
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "note")
        #expect(service.lastTransferIssue == refusal)
    }

    @Test("each promised file rep pastes through its own blocking pull")
    func copyPromisedFilesPasteViaBlockingPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let aBytes = Data((0..<(40 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let bBytes = Data((0..<(30 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 41, repIndex: 0, uti: "public.data", bytes: aBytes, filename: "a.bin",
            isInline: false)
        responder.register(
            generation: 41, repIndex: 1, uti: "public.data", bytes: bBytes, filename: "b.bin",
            isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 41,
                reps: [
                    (uti: "public.data", byteCount: aBytes.count, filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: bBytes.count, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.droppedReasons.isEmpty)

        // Each `.fileURL` fire pulls + stages its own rep on demand, off the main
        // thread here (a paste can also fire it on main).
        let firstURL = await offCooperativePool { service.copyToMacFileURL(generation: 41, repIndex: 0) }
        #expect(try Data(contentsOf: #require(firstURL)) == aBytes)
        let secondURL = await offCooperativePool { service.copyToMacFileURL(generation: 41, repIndex: 1) }
        #expect(try Data(contentsOf: #require(secondURL)) == bBytes)
    }

    @Test("a paste-time fire refuses the whole over-budget file set — no piecemeal pastes")
    func copyPasteTimeRefusesOverTotal() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafePasteBytes) / 2 + 1
        try guest.send(
            makeOffer(
                generation: 43,
                reps: [
                    (uti: "public.data", byteCount: Int(half), filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: Int(half), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // The paste-time gate is its own defense: even a fire that bypassed the
        // click's advisory refusal (which would have dropped these reps) refuses
        // the over-budget set whole, and no host stream is requested.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()
        #expect(service.copyToMacFileURL(generation: 43, repIndex: 0) == nil)
        #expect(service.copyToMacFileURL(generation: 43, repIndex: 1) == nil)
        #expect(responder.requests.isEmpty)
        // A provider fire has no return path to the gesture, so the refusal is
        // reported through the issue the clipboard window renders.
        #expect(
            service.lastTransferIssue?.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage))
    }

    @Test("an image file is paste-bound too — an over-cap image set is refused whole")
    func copyRefusesOverBudgetImageFileSet() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Two image FILES: `is_inline` is true (they paste as images too), yet
        // each is served as `public.file-url` as well, so both count against the
        // paste budget their sum exceeds.
        let png = UTType.png.identifier
        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafePasteBytes) / 2 + 1
        try guest.send(
            makeRawOffer(
                generation: 71,
                reps: [
                    (uti: png, byteCount: half, filename: "a.png", isInline: true),
                    (uti: png, byteCount: half, filename: "b.png", isInline: true),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        // All-or-nothing across the file set, reported on the surfaces a click
        // and an automatic passthrough publish each read.
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        #expect(
            service.lastTransferIssue?.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage))
        // The cap governs the file flavor, not the inline one (§1): each rep
        // still promises, with `.fileURL` withheld from the item it plans.
        #expect(items.promised.map(\.repIndex) == [0, 1])
        #expect(items.promised.map(\.withholdsFileURL) == [true, true])
        let specs = HostClipboardPublisher.promisedItemSpecs(for: items.promised, provider: service)
        let pngType = NSPasteboard.PasteboardType(png)
        #expect(specs.map(\.types) == [[pngType], [pngType]])

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        let bytes = Data(repeating: 0x89, count: 2048)
        responder.register(
            generation: 71, repIndex: 0, uti: png, bytes: bytes, filename: "a.png", isInline: true)
        responder.start()

        // The paste-time gate refuses a `.fileURL` fire on its own, without a
        // request; the same rep's inline flavor still serves its bytes.
        let refused = await offCooperativePool {
            service.copyToMacFileURL(generation: 71, repIndex: 0)
        }
        #expect(refused == nil)
        #expect(responder.requests.isEmpty)
        let inline = await offCooperativePool {
            service.copyToMacData(generation: 71, repIndex: 0, uti: png)
        }
        #expect(inline == bytes)
    }

    @Test("an under-cap image file still pastes through the `.fileURL` path")
    func underCapImageFilePastesThroughFileURL() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let png = UTType.png.identifier
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 72, repIndex: 0, uti: png, bytes: bytes, filename: "shot.png",
            isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 72,
                reps: [(uti: png, byteCount: bytes.count, filename: "shot.png", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let items = service.materializeForCopy()
        #expect(items.droppedReasons.isEmpty)
        #expect(items.promised.map(\.withholdsFileURL) == [false])
        let url = await offCooperativePool { service.copyToMacFileURL(generation: 72, repIndex: 0) }
        #expect(try Data(contentsOf: #require(url)) == bytes)
    }

    @Test("a declared byte count near UInt64.max is bounded at intake, never wrapped")
    func absurdDeclaredByteCountBounded() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        try guest.send(
            makeRawOffer(
                generation: 73,
                reps: [
                    (uti: "public.data", byteCount: .max - 1, filename: "huge.bin", isInline: false)
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // The published placeholder carries the clamped size, so nothing
        // downstream sums, formats, or stages a number that can't be real.
        #expect(
            service.clipboardContent.representations[0].byteCount
                == Int(ClipboardOfferBounds.maxDeclaredByteCount))

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        let items = service.materializeForCopy()
        #expect(items.promised.isEmpty)
        #expect(items.droppedReasons == [.overPasteBudget])
        #expect(
            service.lastTransferIssue?.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage))
        #expect(service.copyToMacFileURL(generation: 73, repIndex: 0) == nil)
        #expect(responder.requests.isEmpty)
    }

    @Test("two reps whose declared sizes sum past UInt64 are refused, not wrapped under the cap")
    func wrappingRepSumRefused() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Unbounded, 2^63 + 2^63 wraps to 0 — a total that passes every cap.
        try guest.send(
            makeRawOffer(
                generation: 74,
                reps: [
                    (uti: "public.data", byteCount: 1 << 63, filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: 1 << 63, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = service.materializeForCopy()
        #expect(items.promised.isEmpty)
        #expect(items.droppedReasons == [.overPasteBudget, .overPasteBudget])
        #expect(service.copyToMacFileURL(generation: 74, repIndex: 0) == nil)
    }

    @Test("an offer declaring more reps than the transfer-id limit is truncated at intake")
    func repCountBoundedAtIntake() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // A rep past the 16-bit rep index a transfer id carries could never be
        // requested, so the offer is bounded to the limit the sender observes.
        let limit = ClipboardContent.maxOfferableRepresentations
        try guest.send(
            makeOffer(
                generation: 75,
                reps: (0..<(limit + 3)).map { index in
                    (uti: "public.data", byteCount: 4, filename: "f\(index).bin", isInline: false)
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
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: 0, progressIdleLinger: 0)
        service.start()
        defer { service.stop() }

        let fileBytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        // Park before End so the transfer is live (bytes received, pull unresolved)
        // while we observe the bar.
        responder.holdEnd = true
        responder.register(
            generation: 41, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "big.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 41,
                reps: [(uti: "public.data", byteCount: fileBytes.count, filename: "big.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let pull = Task {
            await offCooperativePool { service.copyToMacFileURL(generation: 41, repIndex: 0) }
        }

        // The readout reveals mid-flight: inbound, denominated by the rep's total,
        // and naming the file.
        try await waitForChange { service.transferProgress?.direction == .inbound }
        #expect(service.transferProgress?.totalBytes == UInt64(fileBytes.count))
        #expect(service.transferProgress?.currentItemName == "big.bin")
        // Never flagged a paste session, though a paste is what fires it: this pull
        // parks the thread serving the promise — the main thread in production — so
        // the dropdown it popped would only appear once the paste was already over.
        #expect(service.transferProgress?.isPasteSession == false)

        // Releasing End resolves the pull; the terminal clears the readout (§13:
        // never leave a stuck bar).
        responder.releaseEnd()
        let url = await pull.value
        #expect(url != nil)
        try await waitForChange { service.transferProgress == nil }
    }

    @Test(
        "A control frame arriving while a paste pull blocks main does not stall stream-frame routing (#458)"
    )
    func controlFrameDuringBlockingPullDoesNotStallRouting() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // RATIONALE: deliberately far BELOW `testWaitBackstop`, not ≥60 s. This
        // test blocks the real main thread inside `copyToMacFileURL`, so this
        // injected timeout is the ceiling on how long the whole bundle's
        // MainActor can be held hostage if the fast path loses — every
        // concurrently running test's waits freeze for exactly this long. A
        // 60 s value once froze the bundle wall-to-wall and mass-failed 17
        // tests whose 60 s backstops could not outlast it; 5 s bounds the
        // blast radius while staying orders of magnitude above the genuine
        // ms-scale delivery (the responder runs on the now-unpoisoned
        // cooperative pool — see `offCooperativePool`). Under a #458
        // regression the pull resolves to nothing when this fires, so the
        // test fails either way and the value's size never masks it.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", lazyPullTimeout: .seconds(5))
        service.start()
        defer { service.stop() }

        // A single lazy-eligible file rep (non-inline, named) — the paste pull's target.
        try guest.send(
            makeOffer(
                generation: 30,
                reps: [(uti: "public.data", byteCount: 4, filename: "f.bin", isInline: false)]))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let xid = inboundTransferID(generation: 30, repIndex: 0)

        // Drains the guest side independently of the host's main thread: on seeing
        // the host's ClipboardRequest, sends an inert control frame FIRST — the
        // interleaving #458 describes, a control frame landing mid-pull — THEN the
        // stream frames that resolve the pull. `.detached` (not plain `Task {}`,
        // which would inherit this MainActor test struct's isolation) so this
        // truly never touches the host's main actor and isn't blocked by the
        // copyToMacFileURL call below; it is the guest-side analog of the "peer
        // keeps talking while we're mid-transfer" scenario.
        let responderTask = Task.detached {
            for try await frame in guest.incoming {
                guard case .clipboardRequest(let req) = frame.payload, req.transferID == xid
                else { continue }
                try guest.sendErrorFrame(
                    code: "clipboard.interleaved", message: "control frame mid-pull",
                    inReplyTo: "clipboard.request")
                var begin = Frame()
                begin.protocolVersion = 1
                begin.clipboardStreamBegin = Kernova_V1_ClipboardStreamBegin.with {
                    $0.generation = req.generation
                    $0.transferID = req.transferID
                    $0.uti = req.uti
                    $0.totalBytes = UInt64(payload.count)
                    $0.filename = "f.bin"
                    $0.isInline = false
                }
                try guest.send(begin)
                // Inlined rather than calling the suite's `sendChunkAndEnd` helper:
                // that helper is `@MainActor`-isolated (an instance method on this
                // struct), and this closure must stay genuinely off-actor.
                var chunkFrame = Frame()
                chunkFrame.protocolVersion = 1
                chunkFrame.clipboardChunk = Kernova_V1_ClipboardChunk.with {
                    $0.transferID = req.transferID
                    $0.offset = 0
                    $0.data = payload
                }
                try guest.send(chunkFrame)
                var endFrame = Frame()
                endFrame.protocolVersion = 1
                endFrame.clipboardStreamEnd = Kernova_V1_ClipboardStreamEnd.with {
                    $0.transferID = req.transferID
                    $0.totalBytes = UInt64(payload.count)
                    $0.sha256 = Data(SHA256.hash(data: payload))
                }
                try guest.send(endFrame)
                return
            }
        }
        defer { responderTask.cancel() }

        // The pasteboard `provide` callback calls this directly on main — a
        // real synchronous block of the main thread, exactly like production.
        // Under the old `await onControlFrame` code this would hang until the
        // lazyPullTimeout backstop fired and resolved to `.pullFailed`: the
        // interleaved control frame suspends the whole consume loop on the
        // unavailable main actor, so the Begin/Chunk/End behind it in the channel
        // never route and the pull's semaphore never signals. Under the fix, the
        // consume loop dispatches the control frame fire-and-forget and keeps
        // draining — Begin/Chunk/End route immediately regardless of main being
        // blocked — so this resolves promptly.
        guard let url = service.copyToMacFileURL(generation: 30, repIndex: 0) else {
            Issue.record("Expected copyToMacFileURL to serve the rep")
            return
        }
        #expect(try Data(contentsOf: url) == payload)

        // The interleaved control frame wasn't dropped — it's processed
        // fire-and-forget, so it surfaces once main frees up.
        try await waitForChange { service.lastTransferIssue != nil }
        if case .peerReportedError(let code, _) = service.lastTransferIssue?.kind {
            #expect(code == "clipboard.interleaved")
        } else {
            Issue.record("Expected the interleaved control frame's error to surface")
        }
    }

    @Test("A newer offer supersedes an in-flight pull — the pull resolves to nothing, new placeholders publish")
    func newerOfferSupersedesInFlightPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // The responder answers gen=1's request with a Begin **only** (no End):
        // that registers a live transfer in the host's receiver table, so the
        // gen=2 supersede's `cancel(generation: 1)` has something to tear down,
        // which resolves the host's parked pull continuation to nil. The single
        // channel preserves order — the Begin is processed by the receiver before
        // the gen=2 offer reaches handleOffer.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        // An inline rep so the preview pulls it; beginOnly so the pull parks for
        // the supersede to interrupt.
        responder.register(
            generation: 1, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("stale".utf8),
            isInline: true, beginOnly: true)
        responder.start()

        // First offer (gen=1) — a single inline rep, a placeholder until pulled.
        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: ClipboardContent.utf8TextUTI, byteCount: 5, filename: "", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // Start a preview that issues the gen=1 pull and parks (no End arrives).
        let previewTask = Task { await service.materializeForPreview() }
        // Wait until the host has actually sent the pull request — that's the
        // in-flight window we want to interrupt.
        try await responder.answered.wait {
            responder.requests.contains { $0.generation == 1 }
        }

        // A newer offer (gen=2) supersedes gen=1: handleOffer cancels the
        // in-flight receiver transfer, which resolves the parked pull to nil.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))

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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Unlike `newerOfferSupersedesInFlightPull` (beginOnly → pull resolves to
        // nil), gen=1 answers with a COMPLETE transfer, so the pull resolves with
        // real bytes. That is the only path where the `inboundPromise === promise`
        // re-check is load-bearing: a successful pull's bytes would clobber the
        // newer offer's placeholders if the guard didn't suppress the republish.
        let responder = FakeGuestResponder(guest: guest)
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
        try guest.send(makeTextOffer(generation: 1, text: "stale"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The preview issues the gen=1 pull; it completes and parks in the seam.
        let previewTask = Task { await service.materializeForPreview() }
        try await entered.wait { didEnter }

        // The materialize call is parked, so the main actor is free: a newer offer
        // lands and republishes gen=2's placeholder.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        // The test calls stop() itself mid-flow (that is the action under test);
        // this defer is an idempotent safety net for the early-throw path.
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
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

        try guest.send(makeTextOffer(generation: 1, text: "stale"))
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
            service.copyToMacData(
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 8, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data("x".utf8),
            isInline: true)
        responder.start()

        try guest.send(makeTextOffer(generation: 8, text: "x"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The guest releases the offer before the host pulls anything.
        var release = Frame()
        release.protocolVersion = 1
        release.clipboardRelease = Kernova_V1_ClipboardRelease.with { $0.generation = 8 }
        try guest.send(release)

        // Barrier: send a clipboard error frame *after* the release. Both are
        // control frames on the single channel, processed in order, so once the
        // error has surfaced as `lastTransferIssue`, `handleRelease(gen=8)` has
        // already run and dropped the promise — making the copy below race-free.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "release processed",
            inReplyTo: "clipboard.release")
        try await waitForChange { service.lastTransferIssue != nil }

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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // A guest offer leaves clipboardContent holding placeholders.
        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.png", byteCount: 1024, filename: "p.png", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // grabIfChanged must NOT echo placeholder content back to the guest.
        let before = recorder.frames.count
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: before, for: .milliseconds(150))

        // The user replaces the buffer with their own bytes → a grab now offers.
        service.clipboardContent = ClipboardContent(text: "my own text")
        service.grabIfChanged()
        try await waitForFrames(recorder) {
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
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

    @Test("Concurrent preview pulls for the same rep send ONE request, and a later paste fire reads the cache")
    func concurrentPullsForSameRepDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let payload = Data("shared payload".utf8)
        let textUTI = ClipboardContent.utf8TextUTI
        let generation: UInt64 = 17

        // Register the rep as Begin-ONLY: the responder opens the receiver
        // transfer (Begin) but never streams chunks/End, so the host's first
        // pull parks. That parked window is exactly when a second caller must
        // coalesce onto the in-flight pull instead of minting a second
        // same-transfer_id request.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: generation, repIndex: 0, uti: textUTI, bytes: payload,
            isInline: true, beginOnly: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: generation,
                reps: [(uti: textUTI, byteCount: payload.count, filename: "", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First caller: preview pull for rep 0. It sends one request and parks
        // (no End arrives). Run it detached so the test keeps driving.
        let firstPreview = Task { await service.materializeForPreview() }

        // Wait until EXACTLY one request for rep 0 has been recorded — the
        // in-flight window we want the second caller to coalesce into.
        let rep0XID = inboundTransferID(generation: generation, repIndex: 0)
        try await responder.answered.wait {
            responder.requests.contains { $0.transferID == rep0XID }
        }
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)

        // Second caller: another preview loop (a window re-display), while the
        // first pull is still parked — it must observe `inFlight[0]` and await
        // the existing pull.
        let secondPreview = Task { await service.materializeForPreview() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            responder.requests.filter { $0.transferID == rep0XID }.count == 1,
            "A concurrent preview pull must coalesce onto the in-flight one, not mint a second request")

        // Now complete the parked transfer: the Begin was already sent by the
        // responder, so stream the chunks + End directly for that transfer id.
        // Both parked pulls resolve off the single resolved continuation — proving
        // the coalesced caller didn't orphan a continuation or hang.
        try sendChunkAndEnd(from: guest, transferID: rep0XID, bytes: payload)

        await firstPreview.value
        await secondPreview.value

        // The rep was pulled exactly once across both callers, and the shared
        // pull's bytes are committed to the cache (republished to the buffer).
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
        #expect(service.clipboardContent.text == "shared payload")
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.inMemoryData == payload)

        // With the cache settled, a paste-time fire serves it without another
        // request.
        let pasted = await offCooperativePool {
            service.copyToMacData(generation: generation, repIndex: 0, uti: textUTI)
        }
        #expect(pasted == payload)
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
    }

    @Test("A pull the guest never answers (channel open) resolves via the backstop timeout, not a hang")
    func pullBackstopTimeoutResolvesParkedPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A tiny backstop so the parked pull resolves promptly instead of waiting
        // the production 120 s.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)",
            lazyPullTimeout: .milliseconds(200))
        service.start()
        defer { service.stop() }

        // The responder records the host's request but registers NO reply, so it
        // never sends a Begin — and never closes the channel. With no completion,
        // abort, supersession, or teardown to resolve the host's pull, only the
        // backstop timeout can; if it didn't fire, this test would hang.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        try guest.send(
            makeOffer(
                generation: 5,
                reps: [(uti: ClipboardContent.utf8TextUTI, byteCount: 5, filename: "", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // The preview issues the pull; with no answer and the channel open, it
        // must resolve (not hang) once the backstop fires — leaving the rep a
        // placeholder.
        await service.materializeForPreview()

        // The request DID go out (proving the pull started and the backstop, not a
        // pre-send failure, resolved it), and the rep stays a placeholder.
        try await responder.answered.wait {
            responder.requests.contains { $0.generation == 5 }
        }
        #expect(service.clipboardContent.representations.first?.isPendingRemote == true)
    }

    @Test("A local edit after a guest offer wins — Copy-to-Mac copies the edit, not the stale promise")
    func localEditSupersedesInboundPromise() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 3, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("from guest".utf8), isInline: true)
        responder.start()

        try guest.send(makeTextOffer(generation: 3, text: "from guest"))
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

    @Test("A failed preview pull is retried on the next call — the generation latch isn't set on failure")
    func previewRetriesAfterFailedPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // The first pull is failed via an explicit abort (below), not the
        // lazyPullTimeout backstop: the same injected timeout also governs the
        // second pull whose SUCCESS this test asserts, so a small value races
        // the responder's genuine delivery on a stalled runner (docs/TESTING.md's
        // injected-timeout rule). The no-latch-on-failure property under test is
        // failure-kind-agnostic — materializeForPreview skips the generation
        // latch on any nil pull result, timeout and abort alike.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", lazyPullTimeout: .seconds(60))
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        // No reply registered yet → the first pull parks until aborted.
        responder.start()

        try guest.send(makeTextOffer(generation: 2, text: "retry me"))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First attempt: park the pull, then abort it from the guest side. The
        // pull resolves nil and the rep stays a placeholder.
        let firstPreview = Task { await service.materializeForPreview() }
        let xid = inboundTransferID(generation: 2, repIndex: 0)
        try await responder.answered.wait {
            responder.requests.contains { $0.transferID == xid }
        }
        var abort = Frame()
        abort.protocolVersion = 1
        abort.clipboardStreamAbort = Kernova_V1_ClipboardStreamAbort.with {
            $0.transferID = xid
            $0.code = "cancelled"
            $0.message = "test: first pull aborted"
        }
        try guest.send(abort)
        await firstPreview.value
        #expect(service.clipboardContent.representations.first?.isPendingRemote == true)

        // The guest can now answer; a second attempt must retry (not be blocked by
        // a generation latch) and upgrade the placeholder.
        responder.register(
            generation: 2, repIndex: 0, uti: ClipboardContent.utf8TextUTI,
            bytes: Data("retry me".utf8), isInline: true)
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "retry me")
    }

    @Test("An all-identity-skip offer publishes nothing and holds no promise")
    func allSkipOfferHoldsNoPromise() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        // Every rep is an identity-skip (transient marker / raw file-url).
        try guest.send(
            makeOffer(
                generation: 4,
                reps: [
                    (uti: "org.nspasteboard.TransientType", byteCount: 4, filename: "", isInline: true),
                    (uti: "public.file-url", byteCount: 8, filename: "x", isInline: true),
                ]))
        // Barrier: an error frame after the offer; once it surfaces, handleOffer ran.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "offer processed", inReplyTo: "clipboard.offer")
        try await waitForChange { service.lastTransferIssue != nil }

        #expect(service.clipboardContent.isEmpty)
        // No promise is held: Copy-to-Mac resolves nothing and sends no request
        // (mirrors the guest agent's all-skip handling, not a dangling promise).
        let resolved = service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)
        #expect(resolved.promised.isEmpty)
        #expect(responder.requests.isEmpty)
    }

    @Test("A disk-full abort on an in-flight pull surfaces a .diskFull transfer issue")
    func pullDiskFullAbortSurfacesIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // beginOnly opens a transfer the host can then abort with disk.full —
        // exercising the awaiter's onAbort issue-surfacing (the same handler the
        // host's own mid-stream disk-full detection drives via deliverAbort). An
        // image rep is used because the preview pulls it through the async `pull`;
        // the paste-time blocking pull's own reporting is covered below.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 5, repIndex: 0, uti: "public.png", bytes: Data(count: 4096),
            filename: "shot.png", isInline: true, beginOnly: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 5,
                reps: [(uti: "public.png", byteCount: 4096, filename: "shot.png", isInline: true)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let previewTask = Task { await service.materializeForPreview() }
        let xid = inboundTransferID(generation: 5, repIndex: 0)
        try await responder.answered.wait {
            responder.requests.contains { $0.transferID == xid }
        }

        var abort = Frame()
        abort.protocolVersion = 1
        abort.clipboardStreamAbort = Kernova_V1_ClipboardStreamAbort.with {
            $0.transferID = xid
            $0.code = "disk.full"
            $0.message = "volume filled"
        }
        try guest.send(abort)

        await previewTask.value
        try await waitForChange {
            if case .diskFull = service.lastTransferIssue?.kind { return true }
            return false
        }
    }

    // MARK: - Paste-time pull failures

    /// Drives one paste-time `.fileURL` fire whose transfer the guest opens and
    /// then aborts with `code`, returning what the fire served and the issue it
    /// raised.
    ///
    /// A provider fire has no return path to the gesture, so the issue is the
    /// only account of why the paste produced nothing. It is recorded before the
    /// fire returns, so the value read here is not racing it.
    private func pasteFireAbortedByGuest(
        code: String
    ) async throws -> (url: URL?, issue: ClipboardTransferIssue?) {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // `beginOnly` opens the transfer and leaves it live, so the abort below
        // lands on a pull already parked on the coordinator.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 21, repIndex: 0, uti: "public.data", bytes: Data(count: 4096),
            filename: "doc.bin", isInline: false, beginOnly: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 21,
                reps: [(uti: "public.data", byteCount: 4096, filename: "doc.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let fire = Task {
            await offCooperativePool { service.copyToMacFileURL(generation: 21, repIndex: 0) }
        }
        let xid = inboundTransferID(generation: 21, repIndex: 0)
        try await responder.answered.wait {
            responder.requests.contains { $0.transferID == xid }
        }

        var abort = Frame()
        abort.protocolVersion = 1
        abort.clipboardStreamAbort = Kernova_V1_ClipboardStreamAbort.with {
            $0.transferID = xid
            $0.code = code
            $0.message = "aborted"
        }
        try guest.send(abort)
        return (await fire.value, service.lastTransferIssue)
    }

    @Test("a paste-time pull the guest never answers reports the timeout")
    func pasteBlockingPullTimeoutSurfacesIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A tiny backstop so the parked fire resolves promptly instead of waiting
        // the production window.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)",
            lazyPullTimeout: .milliseconds(200))
        service.start()
        defer { service.stop() }

        // The responder answers nothing, so only the inactivity backstop can
        // resolve the fire.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        try guest.send(
            makeOffer(
                generation: 17,
                reps: [(uti: "public.data", byteCount: 4096, filename: "doc.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let url = await offCooperativePool { service.copyToMacFileURL(generation: 17, repIndex: 0) }
        #expect(url == nil)
        #expect(service.lastTransferIssue?.kind == ClipboardTransferIssue.pasteTimedOut().kind)
    }

    @Test("a paste-time pull aborted mid-stream reports the failed transfer")
    func pasteBlockingPullAbortSurfacesIssue() async throws {
        // `read.error` is what the sending side raises when the source file it
        // was streaming can't be read — a failure, not a supersession.
        let (url, issue) = try await pasteFireAbortedByGuest(code: "read.error")
        #expect(url == nil)
        #expect(issue?.kind == ClipboardTransferIssue.pasteTransferFailed().kind)
    }

    @Test(
        "a paste-time pull retired by a teardown or supersession reports nothing",
        arguments: ["cancelled", "superseded", "request.stale"])
    func pasteBlockingPullRetiredAbortStaysQuiet(code: String) async throws {
        // Whatever superseded the offer publishes its own explainer; a paste that
        // served nothing because the offer moved on must not also claim a
        // transfer failure.
        let (url, issue) = try await pasteFireAbortedByGuest(code: code)
        #expect(url == nil)
        #expect(issue == nil)
    }

    @Test("a paste-time pull aborted for a full volume reports the disk, not a generic failure")
    func pasteBlockingPullDiskFullAbortSurfacesIssue() async throws {
        let (url, issue) = try await pasteFireAbortedByGuest(code: "disk.full")
        #expect(url == nil)
        guard case .diskFull = issue?.kind else {
            Issue.record("Expected a diskFull issue, got \(String(describing: issue))")
            return
        }
    }

    @Test("a paste-time pull with no room to stage reports it without starting a transfer")
    func pasteBlockingPullPreflightSurfacesDiskFull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // 1 MiB free: the rep plus the free-space margin doesn't fit.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)",
            freeSpaceProvider: { _ in 1024 * 1024 })
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 19, repIndex: 0, uti: "public.data", bytes: Data(count: 4096),
            filename: "doc.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 19,
                reps: [(uti: "public.data", byteCount: 4096, filename: "doc.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let url = await offCooperativePool { service.copyToMacFileURL(generation: 19, repIndex: 0) }
        #expect(url == nil)
        // The pre-flight runs before the request, so nothing was asked for.
        #expect(responder.requests.isEmpty)
        guard case .diskFull(let needed, let available) = service.lastTransferIssue?.kind else {
            Issue.record(
                "Expected a diskFull issue, got \(String(describing: service.lastTransferIssue))")
            return
        }
        #expect(needed == 4096)
        #expect(available == 1024 * 1024)
    }

    @Test("a copied folder whose archive can't be unpacked reports the unpack failure")
    func pasteFolderUnpackFailureSurfacesIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // The bytes stream and stage fine; they just aren't an `.aar`, so the
        // extract inside the paste's deadline is what fails.
        let notAnArchive = Data("not an archive".utf8)
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 23, repIndex: 0, uti: UTType.folder.identifier, bytes: notAnArchive,
            filename: "MyFolder", isInline: false)
        responder.start()

        try guest.send(
            makeDirectoryOffer(
                generation: 23,
                reps: [
                    (
                        uti: UTType.folder.identifier, byteCount: UInt64(notAnArchive.count),
                        filename: "MyFolder"
                    )
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        let url = await offCooperativePool { service.copyToMacFileURL(generation: 23, repIndex: 0) }
        #expect(url == nil)
        #expect(
            service.lastTransferIssue?.kind
                == ClipboardTransferIssue.pasteFolderUnpackFailed().kind)
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
            channel: host, label: "test-\(UUID().uuidString)", stagingTempRoot: tempRoot)
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
            channel: host, label: "test-\(UUID().uuidString)", stagingTempRoot: tempRoot)
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
            channel: host, label: "test-\(UUID().uuidString)", stagingTempRoot: tempRoot)
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // An offer mixing a legit content rep with two identity-skip reps that a
        // buggy/malicious peer might smuggle: a transient marker and a raw
        // `public.file-url`. Only the legit rep should reach `clipboardContent`.
        try guest.send(
            makeOffer(
                generation: 31,
                reps: [
                    (uti: "org.nspasteboard.TransientType", byteCount: 4, filename: "", isInline: true),
                    (uti: "public.png", byteCount: 1024, filename: "shot.png", isInline: false),
                    (uti: "public.file-url", byteCount: 32, filename: "smuggled", isInline: true),
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

    @Test("a zero-byte rep that is not a directory is still filtered from the placeholders")
    func offerFiltersZeroByteNonDirectoryRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // The empty-payload skip still holds for everything but a directory: a
        // zero-byte file rep carries nothing a paste could serve.
        try guest.send(
            makeOffer(
                generation: 33,
                reps: [
                    (uti: "public.png", byteCount: 0, filename: "nothing.png", isInline: false),
                    (uti: "public.png", byteCount: 1024, filename: "shot.png", isInline: false),
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

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()

        // The window is showing content the user put there.
        let shown = ClipboardContent(representations: [
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("keep me".utf8))
        ])
        service.clipboardContent = shown

        // Every rep of the guest's offer is filtered — an identity-skip type and a
        // zero-byte non-directory rep.
        try guest.send(
            makeOffer(
                generation: 41,
                reps: [
                    (uti: "org.nspasteboard.TransientType", byteCount: 4, filename: "", isInline: true),
                    (uti: "public.png", byteCount: 0, filename: "nothing.png", isInline: false),
                ]))
        // Barrier: an error frame after the offer; once it surfaces, handleOffer ran.
        try guest.sendErrorFrame(
            code: "clipboard.barrier", message: "offer processed", inReplyTo: "clipboard.offer")
        try await waitForChange { service.lastTransferIssue != nil }

        // The drop leaves the shown content alone rather than publishing empty.
        #expect(service.clipboardContent.digest == shown.digest)
        #expect(service.clipboardContent.representations.map(\.uti) == [ClipboardContent.utf8TextUTI])
        // No promise is held: Copy-to-Mac resolves what's shown and asks for nothing.
        let items = service.materializeForCopy()
        #expect(items.resolvedReps.map(\.uti) == [ClipboardContent.utf8TextUTI])
        #expect(items.promised.isEmpty)
        #expect(responder.requests.isEmpty)
    }

    // MARK: - Peer errors

    @Test("Peer clipboard error frame surfaces as a peerReportedError issue")
    func peerErrorSurfacesAsIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        try guest.sendErrorFrame(
            code: "clipboard.transfer.send.failure",
            message: "guest could not deliver",
            inReplyTo: "clipboard.request"
        )

        try await waitForChange { service.lastTransferIssue != nil }
        guard case .peerReportedError(let code, let message) = service.lastTransferIssue?.kind
        else {
            Issue.record("Expected peerReportedError issue, got \(String(describing: service.lastTransferIssue))")
            return
        }
        #expect(code == "clipboard.transfer.send.failure")
        #expect(message == "guest could not deliver")
    }

    // MARK: - Transfer progress

    @Test("an inbound transfer sets transferProgress while in flight and clears it on completion")
    func inboundTransferProgressSetThenCleared() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // `.zero` reveal delay → the transfer shows as soon as a chunk lands.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: 0, progressIdleLinger: 0)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        let text = String(repeating: "K", count: 120 * 1024)  // multi-chunk inline payload
        let bytes = Data(text.utf8)
        responder.register(
            generation: 5, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: bytes,
            isInline: true)
        responder.holdEnd = true  // park before End so the pull stays in flight
        responder.start()
        defer { responder.cancel() }

        try guest.send(makeTextOffer(generation: 5, text: text))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }

        let previewTask = Task { await service.materializeForPreview() }

        // Chunks have landed but End is held → the bar shows, inbound.
        try await waitForChange { (service.transferProgress?.bytesTransferred ?? 0) > 0 }
        #expect(service.transferProgress?.direction == .inbound)
        #expect(service.transferProgress?.totalBytes == UInt64(bytes.count))

        responder.releaseEnd()
        await previewTask.value
        try await waitForChange { service.transferProgress == nil }
    }

    @Test(
        "a rep another loop pulled first leaves the declaring session's readout, which still reaches 100% (#656)"
    )
    func coalescedRepIsDisownedByTheSessionThatDeclaredIt() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Reveal instantly so each session's state is observable as it happens; the
        // linger is sized past any scheduler stall instead of to a "tidy" value,
        // because the sessions here span a gap between two transfers on purpose and
        // an idle terminal firing inside it would end the very session under test.
        // Nothing waits on the linger — `stop()` clears the readout at teardown.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: 0,
            progressIdleLinger: 60)
        service.start()
        defer { service.stop() }

        // Two previewable reps: the preview loop declares BOTH; a paste-time fire
        // will pull rep 1 first, leaving the preview to disown it.
        let text = String(repeating: "x", count: 200_000)
        let rtf = Data(repeating: 0x41, count: 8_192)
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 7, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.register(
            generation: 7, repIndex: 1, uti: "public.rtf", bytes: rtf, isInline: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 7,
                reps: [
                    (
                        uti: ClipboardContent.utf8TextUTI, byteCount: text.utf8.count, filename: "",
                        isInline: true
                    ),
                    (uti: "public.rtf", byteCount: rtf.count, filename: "", isInline: true),
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

        // The preview opens its session first and declares BOTH reps — rep 1 is
        // neither materialized nor in flight yet, which is precisely the state an
        // open-time filter cannot see past.
        let previewTask = Task { await service.materializeForPreview() }
        try await entered.wait { didEnter }

        // The preview's session is on screen, still counting both reps.
        try await waitForChange {
            service.transferProgress?.totalBytes == UInt64(text.utf8.count + rtf.count)
        }
        #expect(service.transferProgress?.fileCount == 2)

        // With it parked, a paste-time fire pulls rep 1 to completion under its
        // own session — the rep the preview declared but will now never own.
        let pasted = await offCooperativePool {
            service.copyToMacData(generation: 7, repIndex: 1, uti: "public.rtf")
        }
        #expect(pasted == rtf)

        released = true
        release.notify()
        await previewTask.value

        // Reaching rep 1 and finding it already pulled, the preview session
        // disowns it, and the readout lands on the bytes it actually moved — at
        // 100%, rather than stalling for the rest of the operation. The total is
        // what identifies the session.
        try await waitForChange { service.transferProgress?.totalBytes == UInt64(text.utf8.count) }
        let final = try #require(service.transferProgress)
        #expect(final.fileCount == 1)
        #expect(final.fractionComplete == 1)
    }

    @Test("an outbound transfer sets transferProgress while streaming and clears it on completion")
    func outboundTransferProgressSetThenCleared() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let label = "test-\(UUID().uuidString)"
        // Its own center rather than the process-wide `.shared` default: the
        // status item renders what lands *here*, so the assertions below cover the
        // service→center hop the menu bar actually reads.
        let center = ClipboardProgressCenter()
        let service = VsockClipboardService(
            channel: host, label: label, progressRevealDelay: 0, progressIdleLinger: 0,
            progressCenter: center)
        service.start()
        defer { service.stop() }

        // A multi-chunk (> 64 KiB) inline payload so a one-chunk credit window
        // leaves the sender blocked mid-transfer with progress showing.
        let text = String(repeating: "K", count: 200 * 1024)
        let expected = Data(text.utf8)
        service.clipboardContent = ClipboardContent(text: text)
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }
        let info = try #require(offer.repInfo.first)
        let xid = transferID(generation: offer.generation, repIndex: 0)
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))

        // Wait for Begin before acking: handleRequest (a control frame, now
        // dispatched fire-and-forget per #458) registers the transfer with the
        // sender — an ack sent before that registration lands would be for a
        // transfer_id the sender doesn't know yet. A real guest can't ack before
        // it, either — Begin is what startTransfer sends, so there's nothing to
        // ack until it arrives.
        let beginFrame = try await nextFrame(from: guest)
        guard case .clipboardStreamBegin = beginFrame.payload else {
            Issue.record("Expected clipboardStreamBegin, got \(String(describing: beginFrame.payload))")
            return
        }

        // First ack: a one-chunk window → the host sends a single 64 KiB chunk
        // then blocks on credit, so progress shows but the transfer isn't done.
        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 64 * 1024)
        try await waitForChange { (service.transferProgress?.bytesTransferred ?? 0) > 0 }
        let readout = try #require(service.transferProgress)
        #expect(readout.direction == .outbound)
        #expect(readout.totalBytes == UInt64(expected.count))
        // A guest request is always a paste in the guest — its only originator is
        // the pasteboard promise callback — so this readout is the one allowed to
        // open the status-item dropdown, and it says whose paste it is serving.
        #expect(readout.isPasteSession)
        #expect(
            ClipboardProgressFormat.headline(
                direction: readout.direction, peerName: readout.peerName,
                isPaste: readout.isPasteSession) == "Pasting into “\(label)”…")

        // The aggregate the status item renders, not just this service's own copy.
        let aggregate = try #require(center.materializationProgress)
        #expect(aggregate.isPasteSession)
        #expect(aggregate.direction == .outbound)

        // Open the window fully → the rest streams and the transfer completes.
        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 2 * 1024 * 1024)
        try await waitForChange { service.transferProgress == nil }
        try await waitForChange { center.materializationProgress == nil }
    }

    @Test("a transfer that finishes before the reveal delay never shows progress")
    func transferBelowRevealDelayNeverShows() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A reveal delay long enough that the fast transfer completes first.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: 3600, progressIdleLinger: 0)
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        let text = "small"
        responder.register(
            generation: 9, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.start()
        defer { responder.cancel() }

        try guest.send(makeTextOffer(generation: 9, text: text))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }

        await service.materializeForPreview()
        #expect(service.clipboardContent.text == text)  // the transfer completed
        #expect(service.transferProgress == nil)  // but it never crossed the reveal delay
    }

    @Test("stop() clears an in-flight transferProgress")
    func stopClearsTransferProgress() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: 0, progressIdleLinger: 0)
        service.start()

        let responder = FakeGuestResponder(guest: guest)
        let text = String(repeating: "S", count: 120 * 1024)  // multi-chunk inline payload
        responder.register(
            generation: 3, repIndex: 0, uti: ClipboardContent.utf8TextUTI, bytes: Data(text.utf8),
            isInline: true)
        responder.holdEnd = true
        responder.start()
        defer { responder.cancel() }

        try guest.send(makeTextOffer(generation: 3, text: text))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }
        let previewTask = Task { await service.materializeForPreview() }
        try await waitForChange { service.transferProgress != nil }

        service.stop()
        #expect(service.transferProgress == nil)

        responder.releaseEnd()
        await previewTask.value
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
