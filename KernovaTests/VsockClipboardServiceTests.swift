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
                if case .clipboardStreamAbort = $0.payload { return true }; return false
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

        // Wrong uti for rep 0 → rejected with an Abort (was: silently dropped).
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
                if case .clipboardStreamAbort = $0.payload { return true }; return false
            })
        guard case .clipboardStreamAbort(let abort) = abortFrame.payload else {
            Issue.record("Expected clipboardStreamAbort")
            return
        }
        #expect(abort.code == "request.uti")

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
                            try self.stream(req: req, reply: reply)
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
        private func stream(req: Kernova_V1_ClipboardRequest, reply: Reply) throws {
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

        try await waitUntil { service.clipboardContent.representations.count == 2 }
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

        try await waitUntil {
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

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
        try await waitUntil { service.clipboardContent.representations.count == 3 }

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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "x")
        let afterFirst = responder.requests.count
        #expect(afterFirst == 1)

        // A second call for the same offer pulls nothing (guarded by
        // previewMaterializationStarted).
        await service.materializeForPreview()
        #expect(responder.requests.count == afterFirst)
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        await service.materializeForPreview()
        #expect(service.clipboardContent.representations.first?.inMemoryData == bytes)
    }

    @Test("materializeForCopy pulls every remaining rep — files become .file, inline become .inMemory")
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
        try await waitUntil { service.clipboardContent.representations.count == 2 }

        let resolved = await service.materializeForCopy()

        // The returned content is fully materialized, in offer order.
        #expect(resolved.representations.count == 2)
        let inline = resolved.representations[0]
        #expect(!inline.isPendingRemote)
        #expect(inline.inMemoryData == inlineBytes)

        let file = resolved.representations[1]
        #expect(!file.isPendingRemote)
        #expect(file.filename == "from-guest.bin")
        let url = try #require(file.fileURL, "Expected a file-backed representation")
        #expect(try Data(contentsOf: url) == fileBytes)
        // The observable buffer mirrors the resolved content.
        #expect(service.clipboardContent.representations.allSatisfy { !$0.isPendingRemote })
    }

    @Test("materializeForCopy resolves preview-pulled reps without re-requesting them")
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
        try await waitUntil { service.clipboardContent.representations.count == 2 }

        // Preview pulls only rep 0 (the inline text); the file rep stays pending.
        await service.materializeForPreview()
        #expect(responder.requests.count == 1)

        // Copy pulls the remaining file rep only — rep 0 is reused from preview.
        let resolved = await service.materializeForCopy()
        #expect(responder.requests.count == 2)
        // No rep was requested twice.
        #expect(Set(responder.requests.map(\.transferID)).count == 2)
        #expect(resolved.representations.count == 2)
        #expect(resolved.representations[0].inMemoryData == inlineBytes)
        let copiedFileURL = try #require(resolved.representations[1].fileURL)
        #expect(try Data(contentsOf: copiedFileURL) == fileBytes)
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
        responder.register(
            generation: 1, repIndex: 0, uti: "public.data", bytes: Data(count: 4096),
            filename: "stale.bin", isInline: false, beginOnly: true)
        responder.start()

        // First offer (gen=1) — a single non-inline file rep.
        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.data", byteCount: 4096, filename: "stale.bin", isInline: false)]))
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        // Start a copy that issues the gen=1 pull and parks (no End ever arrives).
        let copyTask = Task { await service.materializeForCopy() }
        // Wait until the host has actually sent the pull request — that's the
        // in-flight window we want to interrupt.
        try await responder.answered.wait(timeout: .seconds(5)) {
            responder.requests.contains { $0.generation == 1 }
        }

        // A newer offer (gen=2) supersedes gen=1: handleOffer cancels the
        // in-flight receiver transfer, which resolves the parked pull to nil.
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))

        // The superseded copy resolves to nothing materialized for the abandoned
        // offer — every returned rep is still a placeholder (or the result is
        // empty), and no rep was committed.
        let resolved = await copyTask.value
        #expect(resolved.representations.allSatisfy { $0.isPendingRemote })

        // The new offer's placeholder is what's published.
        try await waitUntil {
            service.clipboardContent.representations.first?.filename == "new.png"
        }
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.isPendingRemote)
        #expect(rep.uti == "public.png")
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

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
        try await waitUntil { service.lastTransferIssue != nil }

        // After release, the promise is gone: materializeForCopy resolves nothing
        // new and never requests the rep.
        let resolved = await service.materializeForCopy()
        #expect(resolved.representations.allSatisfy { $0.isPendingRemote })
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

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

    @Test("Concurrent preview + Copy-to-Mac pulls for the same rep send ONE request and both resolve")
    func concurrentPullsForSameRepDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // A single small inline-text rep: eagerly previewable AND pulled by
        // Copy-to-Mac, so both materialize paths target the same rep index.
        let payload = Data("shared payload".utf8)
        let textUTI = ClipboardContent.utf8TextUTI
        let generation: UInt64 = 17

        // Register the rep as Begin-ONLY: the responder opens the receiver
        // transfer (Begin) but never streams chunks/End, so the host's first
        // pull parks. That parked window is exactly when the second (Copy)
        // caller must coalesce onto the in-flight pull instead of minting a
        // second same-transfer_id request.
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First caller: preview pull for rep 0. It sends one request and parks
        // (no End arrives). Run it detached so the test keeps driving.
        let previewTask = Task { await service.materializeForPreview() }

        // Wait until EXACTLY one request for rep 0 has been recorded — the
        // in-flight window we want the Copy caller to coalesce into.
        let rep0XID = inboundTransferID(generation: generation, repIndex: 0)
        try await responder.answered.wait(timeout: .seconds(5)) {
            responder.requests.contains { $0.transferID == rep0XID }
        }
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)

        // Second caller: Copy-to-Mac, while the preview pull is still parked.
        let copyTask = Task { await service.materializeForCopy() }

        // The dedup means NO second request for rep 0 is minted: Copy awaits the
        // in-flight preview pull. Give the Copy task a beat to reach `materialize`
        // and observe `inFlight[0]`, then assert the request count is unchanged.
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            responder.requests.filter { $0.transferID == rep0XID }.count == 1,
            "A concurrent Copy pull must coalesce onto the in-flight preview pull, not mint a second request")

        // Now complete the parked transfer: the Begin was already sent by the
        // responder, so stream the chunks + End directly for that transfer id.
        // Both parked pulls resolve off the single resolved continuation — proving
        // the coalesced caller didn't orphan a continuation or hang.
        try sendChunkAndEnd(from: guest, transferID: rep0XID, bytes: payload)

        // Both callers complete (no hang). `copyContent` is the Copy-to-Mac
        // result captured *during* the concurrent pull.
        await previewTask.value
        let copyContent = await copyTask.value

        // The rep was pulled exactly once across both callers: still only one
        // request for rep 0 ever went out, and the single shared pull's bytes are
        // committed to the cache (republished to the observable buffer).
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
        #expect(service.clipboardContent.text == "shared payload")
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(!rep.isPendingRemote)
        #expect(rep.inMemoryData == payload)

        // Regression guard for #355: the Copy-to-Mac result captured *during* the
        // concurrent pull must include the coalesced rep. `materializeForCopy`
        // collects each pull's return value rather than rebuilding from the cache,
        // so a caller that coalesces onto an in-flight pull (and resumes before the
        // owning call commits the cache) no longer silently drops the rep.
        #expect(copyContent.representations.count == 1)
        #expect(copyContent.representations.first?.inMemoryData == payload)

        // With the cache now settled (no in-flight pull), a fresh Copy-to-Mac
        // resolves the rep from the cache without re-requesting it.
        let settledCopy = await service.materializeForCopy()
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
        #expect(settledCopy.representations.count == 1)
        #expect(settledCopy.representations.first?.inMemoryData == payload)
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        // Copy issues the pull; with no answer and the channel open, it must
        // resolve (not hang) once the backstop fires — dropping the un-pulled rep.
        let resolved = await service.materializeForCopy()
        #expect(resolved.representations.isEmpty)

        // The request DID go out (proving the pull started and the backstop, not a
        // pre-send failure, resolved it), and the rep stays a placeholder.
        try await responder.answered.wait(timeout: .seconds(5)) {
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
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }
        await service.materializeForPreview()
        #expect(service.clipboardContent.text == "from guest")

        // The user edits the guest-offered text in place (the window writes the
        // edit into the buffer). The inbound promise is now stale.
        service.clipboardContent = ClipboardContent(text: "my edit")

        // Copy-to-Mac must copy the edit, never resurrect the guest's offered rep.
        let resolved = await service.materializeForCopy()
        #expect(resolved.text == "my edit")
        #expect(resolved.representations.allSatisfy { !$0.isPendingRemote })
    }

    @Test("A failed preview pull is retried on the next call — the generation latch isn't set on failure")
    func previewRetriesAfterFailedPull() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Tiny backstop so the first (unanswered) pull fails fast.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", lazyPullTimeout: .milliseconds(150))
        service.start()
        defer { service.stop() }

        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        // No reply registered yet → the first pull times out.
        responder.start()

        try guest.send(makeTextOffer(generation: 2, text: "retry me"))
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First attempt: the pull times out, the rep stays a placeholder.
        await service.materializeForPreview()
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
        try await waitUntil { service.lastTransferIssue != nil }

        #expect(service.clipboardContent.isEmpty)
        // No promise is held: Copy-to-Mac resolves nothing and sends no request
        // (mirrors the guest agent's all-skip handling, not a dangling promise).
        let resolved = await service.materializeForCopy()
        #expect(resolved.isEmpty)
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
        // host's own mid-stream disk-full detection drives via deliverAbort).
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 5, repIndex: 0, uti: "public.data", bytes: Data(count: 4096),
            filename: "big.bin", isInline: false, beginOnly: true)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 5,
                reps: [(uti: "public.data", byteCount: 4096, filename: "big.bin", isInline: false)]))
        try await waitUntil { service.clipboardContent.representations.first?.isPendingRemote == true }

        let copyTask = Task { await service.materializeForCopy() }
        let xid = inboundTransferID(generation: 5, repIndex: 0)
        try await responder.answered.wait(timeout: .seconds(5)) {
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

        _ = await copyTask.value
        try await waitUntil {
            if case .diskFull = service.lastTransferIssue?.kind { return true }
            return false
        }
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
        try await waitUntil {
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

    // NOTE: Disk-full at the service level (`pull`'s free-space pre-flight) is
    // not exercised here. The free-space provider is injectable on the service's
    // staging (`freeSpaceProvider:`), but the host pull's pre-flight reaches it
    // through `ClipboardFileStaging.hasCapacity`, covered at the engine level by
    // `ClipboardStreamTests`. A service-level disk-full test would duplicate that
    // coverage without exercising new host logic; the host's behavior on a failed
    // pull (the rep stays a placeholder, `lastTransferIssue == .diskFull`) is the
    // same as on any aborted pull, which `releaseDropsPromise` and
    // `newerOfferSupersedesInFlightPull` already cover via the abort path.

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
