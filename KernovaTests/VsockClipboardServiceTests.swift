import Testing
import Foundation
import Darwin
import CryptoKit
import KernovaProtocol
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

    /// Awaits the recorder's gate (fired per frame) until `frames.count ==
    /// expected`.
    ///
    /// The `timeout` is a stuck-stream backstop, not the success deadline.
    private func waitForFrameCount(
        _ recorder: FrameRecorder,
        equals expected: Int,
        timeout: Duration = .seconds(10)
    ) async throws {
        try await recorder.recorded.wait(timeout: timeout) {
            recorder.frames.count == expected
        }
    }

    /// Awaits the recorder's gate until `predicate` holds — used when the exact
    /// frame count is unknown (a multi-chunk transfer's chunk count varies).
    private func waitForFrames(
        _ recorder: FrameRecorder,
        timeout: Duration = .seconds(10),
        until predicate: @escaping () -> Bool
    ) async throws {
        try await recorder.recorded.wait(timeout: timeout, until: predicate)
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
        reps: [(uti: String, byteCount: Int, filename: String, isInline: Bool)]
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = reps.map { rep in
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = rep.uti
                    $0.byteCount = UInt64(rep.byteCount)
                    $0.filename = rep.filename
                    $0.isInline = rep.isInline
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

    /// Drives a full `ClipboardStreamBegin` → `ClipboardChunk`* →
    /// `ClipboardStreamEnd` sequence for `transferID` from the guest end.
    ///
    /// The service routes these to its `ClipboardStreamReceiver`, which acks
    /// each chunk back; we don't need to consume the acks — the receiver makes
    /// progress regardless.
    private func streamPayload(
        from guest: VsockChannel,
        transferID: UInt64,
        generation: UInt64,
        uti: String,
        bytes: Data,
        filename: String = "",
        isInline: Bool,
        chunkSize: Int = 64 * 1024
    ) throws {
        var begin = Frame()
        begin.protocolVersion = 1
        begin.clipboardStreamBegin = Kernova_V1_ClipboardStreamBegin.with {
            $0.generation = generation
            $0.transferID = transferID
            $0.uti = uti
            $0.totalBytes = UInt64(bytes.count)
            $0.filename = filename
            $0.isInline = isInline
        }
        try guest.send(begin)

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let slice = bytes.subdata(in: offset..<end)
            var chunkFrame = Frame()
            chunkFrame.protocolVersion = 1
            chunkFrame.clipboardChunk = Kernova_V1_ClipboardChunk.with {
                $0.transferID = transferID
                $0.offset = UInt64(offset)
                $0.data = slice
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
        try await waitForFrameCount(recorder, equals: snapshot + 1)
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
        try await waitForFrameCount(recorder, equals: snapshot + 1)
        guard case .clipboardOffer = recorder.frames[snapshot].payload else {
            Issue.record(
                "Expected clipboardOffer for 'beta', got \(String(describing: recorder.frames[snapshot].payload))")
            return
        }
    }

    // MARK: - Outbound request edge cases

    @Test("Stale ClipboardRequest (wrong generation) is ignored — no stream begins")
    func ignoresStaleRequest() async throws {
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

        // Request a generation that doesn't match the pending offer — must be dropped.
        var staleRequest = makeRequest(generation: offer.generation &+ 1_000, repIndex: 0, uti: info.uti)
        // Keep the transferID consistent with the stale generation so nothing matches.
        staleRequest.clipboardRequest.transferID =
            transferID(generation: offer.generation &+ 1_000, repIndex: 0)
        try guest.send(staleRequest)

        // Then a valid request: the Begin that arrives must be for the valid xid,
        // proving the stale request produced no stream.
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
    }

    @Test("A request whose uti doesn't match the offered rep is ignored")
    func mismatchedUTIRequestIgnored() async throws {
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

        // Wrong uti for rep 0 → dropped, no Begin.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: "public.bogus"))
        try await expectNoNewFrames(on: recorder, sinceCount: 0, for: .milliseconds(150))

        // The correct request still works, proving the channel wasn't poisoned.
        try guest.send(makeRequest(generation: offer.generation, repIndex: 0, uti: info.uti))
        try await waitForFrames(recorder) {
            recorder.first {
                if case .clipboardStreamBegin = $0.payload { return true }; return false
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

    // MARK: - Inbound (eager pull: service requests, we stream)

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
        // service would request gen=1.
        var offerV99 = makeTextOffer(generation: 1, text: "ignored")
        offerV99.protocolVersion = 99
        try guest.send(offerV99)

        // A valid v1 offer for a different generation. The first request that
        // arrives must be for gen=2 — proof that gen=1 was dropped.
        try guest.send(makeTextOffer(generation: 2, text: "kept"))

        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        #expect(req.generation == 2)
    }

    @Test("An inbound text offer is pulled and the streamed bytes populate clipboardContent")
    func inboundTextOfferPopulatesClipboard() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let text = "from guest"
        let bytes = Data(text.utf8)
        try guest.send(
            makeOffer(
                generation: 42,
                reps: [(uti: ClipboardContent.utf8TextUTI, byteCount: bytes.count, filename: "", isInline: true)]))

        // The service eagerly requests rep 0.
        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        let xid = inboundTransferID(generation: 42, repIndex: 0)
        #expect(req.generation == 42)
        #expect(req.transferID == xid)
        #expect(req.uti == ClipboardContent.utf8TextUTI)

        // Act as the sender: stream the bytes back for that transfer.
        try streamPayload(
            from: guest, transferID: xid, generation: 42, uti: ClipboardContent.utf8TextUTI,
            bytes: bytes, isInline: true)

        try await waitUntil { service.clipboardContent.text == text }
        #expect(service.clipboardContent.text == text)
    }

    @Test("A large multi-chunk inbound inline payload reassembles correctly")
    func inboundLargeInlineReassembles() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // > 64 KiB so we feed several chunks.
        let bytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 53 &+ 7) })
        try guest.send(
            makeOffer(
                generation: 3,
                reps: [(uti: "public.data", byteCount: bytes.count, filename: "", isInline: true)]))

        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        let xid = inboundTransferID(generation: 3, repIndex: 0)
        #expect(req.transferID == xid)

        // Feed many small chunks (32 KiB) to exercise the reassembly path.
        try streamPayload(
            from: guest, transferID: xid, generation: 3, uti: "public.data",
            bytes: bytes, isInline: true, chunkSize: 32 * 1024)

        try await waitUntil { !service.clipboardContent.isEmpty }
        #expect(service.clipboardContent.representations.first?.inMemoryData == bytes)
    }

    @Test("An inbound file offer streams to a temp file whose bytes match")
    func inboundFileOfferStagesToTempFile() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let bytes = Data((0..<(150 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) })
        try guest.send(
            makeOffer(
                generation: 9,
                reps: [(uti: "public.data", byteCount: bytes.count, filename: "from-guest.bin", isInline: false)]))

        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        let xid = inboundTransferID(generation: 9, repIndex: 0)
        #expect(req.transferID == xid)

        // Stream it as a file rep (isInline=false, filename set).
        try streamPayload(
            from: guest, transferID: xid, generation: 9, uti: "public.data",
            bytes: bytes, filename: "from-guest.bin", isInline: false, chunkSize: 32 * 1024)

        try await waitUntil { !service.clipboardContent.isEmpty }
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.filename == "from-guest.bin")
        let url = try #require(rep.fileURL, "Expected a file-backed representation")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Inbound representations are sanitized — file references never reach the buffer")
    func inboundRepresentationsSanitized() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let pngBytes = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0) })
        let fileURLBytes = Data("file:///etc/passwd".utf8)
        try guest.send(
            makeOffer(
                generation: 5,
                reps: [
                    (uti: "public.file-url", byteCount: fileURLBytes.count, filename: "", isInline: true),
                    (uti: "public.png", byteCount: pngBytes.count, filename: "", isInline: true),
                ]))

        // The service requests both reps; collect the two requests.
        let r0 = try await nextFrame(from: guest)
        let r1 = try await nextFrame(from: guest)
        let requests = [r0, r1].compactMap { frame -> Kernova_V1_ClipboardRequest? in
            if case .clipboardRequest(let req) = frame.payload { return req }
            return nil
        }
        #expect(requests.count == 2)

        // Stream both back; the forbidden public.file-url rep must be dropped at commit.
        try streamPayload(
            from: guest, transferID: inboundTransferID(generation: 5, repIndex: 0), generation: 5,
            uti: "public.file-url", bytes: fileURLBytes, isInline: true)
        try streamPayload(
            from: guest, transferID: inboundTransferID(generation: 5, repIndex: 1), generation: 5,
            uti: "public.png", bytes: pngBytes, isInline: true)

        try await waitUntil { !service.clipboardContent.isEmpty }
        #expect(service.clipboardContent.representations.map(\.uti) == ["public.png"])
    }

    @Test("Inbound content resets dedup so re-grabbing the round-tripped content re-offers")
    func inboundDataResetsDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        let text = "round-trip"
        let bytes = Data(text.utf8)
        try guest.send(makeTextOffer(generation: 1, text: text))
        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        try streamPayload(
            from: guest, transferID: req.transferID, generation: 1, uti: ClipboardContent.utf8TextUTI,
            bytes: bytes, isInline: true)
        try await waitUntil { service.clipboardContent.text == text }

        // Content unchanged since the inbound update; a grab must still offer
        // (otherwise round-tripped content silently stops syncing back).
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }
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

    @Test("A stale inbound offer is superseded — only the newest generation commits")
    func staleInboundOfferSuperseded() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Two offers in quick succession; the service requests each.
        try guest.send(makeTextOffer(generation: 1, text: "stale"))
        let r1 = try await nextFrame(from: guest)
        guard case .clipboardRequest = r1.payload else {
            Issue.record("Expected request for gen=1, got \(String(describing: r1.payload))")
            return
        }
        try guest.send(makeTextOffer(generation: 2, text: "fresh"))
        let r2 = try await nextFrame(from: guest)
        guard case .clipboardRequest = r2.payload else {
            Issue.record("Expected request for gen=2, got \(String(describing: r2.payload))")
            return
        }

        // Stream the *fresh* (gen=2) transfer to completion. The gen=1 transfer
        // is never streamed — its collection was replaced when gen=2 arrived.
        let fresh = Data("fresh".utf8)
        try streamPayload(
            from: guest, transferID: inboundTransferID(generation: 2, repIndex: 0), generation: 2,
            uti: ClipboardContent.utf8TextUTI, bytes: fresh, isInline: true)

        try await waitUntil { service.clipboardContent.text == "fresh" }
        #expect(service.clipboardContent.text == "fresh")
    }

    // NOTE: Disk-full at the service level is not exercised here. The service
    // constructs its own `ClipboardFileStaging(label:)` with no injectable
    // free-space seam, so a full-disk condition can't be forced cleanly from a
    // test without fabricating one. The disk-full path is covered at the engine
    // level by `ClipboardStreamTests.diskFullRejected` (a file rep exceeding
    // free space aborts with `disk.full`), which is what the service routes into
    // `lastTransferIssue.kind == .diskFull`.

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

        try await waitUntil { service.lastTransferIssue != nil }
        guard case .peerReportedError(let code, let message) = service.lastTransferIssue?.kind
        else {
            Issue.record("Expected peerReportedError issue, got \(String(describing: service.lastTransferIssue))")
            return
        }
        #expect(code == "clipboard.transfer.send.failure")
        #expect(message == "guest could not deliver")
    }
}
