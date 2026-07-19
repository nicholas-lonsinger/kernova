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

    /// The canned domain root the fake coordinator builds paste-routed URLs under.
    private static let fakeDomainRoot = URL(
        fileURLWithPath: "/Users/Shared/KernovaClipboardMac", isDirectory: true)

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
        equals expected: Int
    ) async throws {
        try await recorder.recorded.wait {
            recorder.frames.count == expected
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
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.isConcealed = isConcealed
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

    /// Thread-safe recorder for the `pullStagedFile` `onProgress` pushes (#426),
    /// which fire off the main actor on the transfer's serial queue.
    private final class ServicingProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(bytes: UInt64, total: UInt64)] = []
        func record(_ bytes: UInt64, _ total: UInt64) {
            lock.withLock { entries.append((bytes, total)) }
        }
        var all: [(bytes: UInt64, total: UInt64)] { lock.withLock { entries } }
        var last: (bytes: UInt64, total: UInt64)? { lock.withLock { entries.last } }
        var count: Int { lock.withLock { entries.count } }
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

    @Test("materializeForCopy pulls inline reps eagerly and defers the file rep to a lazy pull")
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

        let items = await service.materializeForCopy()

        // The inline rep is pulled eagerly; the single plain file rep is deferred
        // as a lazy item (the File Provider is off in the test host) — not pulled
        // at copy-click (the eager staging bridge is gone, #424).
        #expect(items.resolvedReps.count == 1)
        let inline = try #require(items.resolvedReps.first)
        #expect(!inline.isPendingRemote)
        #expect(inline.inMemoryData == inlineBytes)

        #expect(items.lazyFiles.count == 1)
        let lazy = try #require(items.lazyFiles.first)
        #expect(lazy.generation == 9)
        #expect(lazy.repIndex == 1)
        #expect(lazy.filename == "from-guest.bin")

        // The lazy file pulls + stages its bytes on demand through the shared
        // bridge (the toggle-off paste path), off the main thread.
        let outcome = await Task.detached {
            service.pullStagedFile(generation: 9, repIndex: 1)
        }.value
        guard case .success(let path) = outcome else {
            Issue.record("Expected pullStagedFile to succeed, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fileBytes)
    }

    @Test("materializeForCopy re-tags a directory offer's rep as a directory")
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
        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = 11
            $0.repInfo = [
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = UTType.folder.identifier
                    $0.byteCount = UInt64(aarBytes.count)
                    $0.filename = "MyFolder"
                    $0.isInline = false
                    $0.isDirectory = true
                }
            ]
        }
        try guest.send(offer)
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // A directory rep stays eager (D2 is single non-directory file): it's
        // pulled and resolved at copy, re-tagged as a directory.
        let items = await service.materializeForCopy()
        #expect(items.resolvedReps.count == 1)
        let rep = try #require(items.resolvedReps.first)
        // The re-tag carried the directory flag from the offer onto the rep.
        #expect(rep.isDirectory)
        // Its bytes are the streamed `.aar`, ready to extract on Copy-to-Mac.
        let url = try #require(rep.fileURL)
        #expect(try Data(contentsOf: url) == aarBytes)
    }

    @Test("with the dir-tree capability, a directory rep defers as a lazy tree instead of being pulled")
    func copyDirectoryRepDefersLazilyWithDirTree() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Availability unprobed at click (`.inactive`), so no advisory refusal;
        // the directory rep routes at paste time as a placeholder tree.
        let coordinator = FakeHostClipboardDomainCoordinator(availability: .inactive)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        // The guest advertised `clipboard.dirtree.v1`.
        service.peerSupportsDirTree = { true }
        service.start()
        defer { service.stop() }

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = 61
            $0.repInfo = [
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = UTType.folder.identifier
                    $0.byteCount = 4_096  // stat-walk estimate
                    $0.filename = "MyFolder"
                    $0.isInline = false
                    $0.isDirectory = true
                }
            ]
        }
        try guest.send(offer)
        try await waitForChange { service.clipboardContent.representations.count == 1 }

        // With the capability, the directory rep is lazy-eligible: it defers as a
        // `.lazyFile` (routed as a placeholder tree at paste), not pulled eagerly.
        let items = await service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.lazyFiles.map(\.repIndex) == [0])
        #expect(items.lazyFiles.first?.filename == "MyFolder")
        #expect(items.droppedReasons.isEmpty)
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
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Preview pulls only rep 0 (the inline text); the file rep stays pending.
        await service.materializeForPreview()
        #expect(responder.requests.count == 1)

        // Copy reuses rep 0 from preview (no re-request) and defers the file rep as
        // a lazy item — so still only the one preview request has gone out.
        let items = await service.materializeForCopy()
        #expect(responder.requests.count == 1)
        #expect(items.resolvedReps.count == 1)
        #expect(items.resolvedReps.first?.inMemoryData == inlineBytes)
        #expect(items.lazyFiles.count == 1)
        #expect(items.lazyFiles.first?.repIndex == 1)

        // The deferred file pulls its bytes on demand through the shared bridge —
        // now the second request goes out, the file rep was never double-requested.
        let outcome = await Task.detached {
            service.pullStagedFile(generation: 6, repIndex: 1)
        }.value
        guard case .success(let path) = outcome else {
            Issue.record("Expected pullStagedFile to succeed, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fileBytes)
        #expect(responder.requests.count == 2)
        #expect(Set(responder.requests.map(\.transferID)).count == 2)
    }

    @Test("materializeForCopy defers every plain-file rep as its own lazy item (D1b multi-file)")
    func copyDefersEveryPlainFileRep() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // Two plain file reps — the single-file D2 scope limit is dissolved (#559):
        // every eligible plain-file rep defers as its own lazy item, routed at
        // paste time. Nothing is pulled at copy-click.
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

        let items = await service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.lazyFiles.map(\.repIndex) == [0, 1])
        #expect(items.lazyFiles.map(\.filename) == ["a.bin", "b.bin"])
        #expect(items.droppedReasons.isEmpty)
        // No pull at copy-click — bytes materialize on read at paste.
        #expect(responder.requests.isEmpty)
    }

    @Test("advisory refuses the over-total plain-file set when the File Provider is known unusable")
    func copyAdvisoryRefusesOverTotalWhenUnusable() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // The File Provider is confirmed off (toggle off), so the copy-click
        // advisory fires and the user sees the message in the window immediately.
        let coordinator = FakeHostClipboardDomainCoordinator(availability: .needsEnabling)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        service.start()
        defer { service.stop() }

        // Two files each under the cap but whose TOTAL exceeds it — the deadline
        // gate is all-or-nothing over the total (decision 4), so the whole set is
        // refused rather than pasted piecemeal.
        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) / 2 + 1
        try guest.send(
            makeOffer(
                generation: 13,
                reps: [
                    (uti: "public.data", byteCount: Int(half), filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: Int(half), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = await service.materializeForCopy()
        #expect(items.resolvedReps.isEmpty)
        #expect(items.lazyFiles.isEmpty)
        #expect(items.droppedReasons == [.tooLargeWithoutFileProvider, .tooLargeWithoutFileProvider])
        // The advisory refuses up-front — no File Provider publish at click.
        #expect(coordinator.publishCallCount == 0)
        #expect(coordinator.prepareCount == 0)
    }

    @Test("multi-file: every plain-file rep routes through the File Provider on the first paste fire")
    func copyRoutesEveryFileThroughFileProvider() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let coordinator = FakeHostClipboardDomainCoordinator(
            availability: .ready, rootToReturn: Self.fakeDomainRoot)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        service.start()
        defer { service.stop() }

        try guest.send(
            makeOffer(
                generation: 40,
                reps: [
                    (uti: "public.data", byteCount: 10, filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: 20, filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        // Every plain-file rep defers as a lazy item — nothing publishes at click,
        // but the servicing relay is warmed for the paste.
        let items = await service.materializeForCopy()
        #expect(items.lazyFiles.map(\.repIndex) == [0, 1])
        #expect(items.droppedReasons.isEmpty)
        #expect(coordinator.publishCallCount == 0)
        #expect(coordinator.prepareCount == 1)

        // The first `.fileURL` fire publishes ALL eligible reps together (one call)
        // and serves its own item's domain URL — no host stream (bytes page in via
        // fetchContents).
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()
        let first = service.copyToMacFileURL(generation: 40, repIndex: 0)
        #expect(first == Self.fakeDomainRoot.appendingPathComponent("a.bin"))
        #expect(coordinator.publishCallCount == 1)
        #expect(coordinator.published.map(\.repIndex) == [0, 1])

        // The sibling item's fire reads the latch — no second publish.
        let second = service.copyToMacFileURL(generation: 40, repIndex: 1)
        #expect(second == Self.fakeDomainRoot.appendingPathComponent("b.bin"))
        #expect(coordinator.publishCallCount == 1)
        #expect(responder.requests.isEmpty)
    }

    @Test("File Provider unusable + under the total cap: every plain-file rep pastes as its own capped sync item")
    func copyUnusableUnderTotalPastesSyncItems() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Registered but toggle off → publishes decline; under-total, so no
        // advisory refusal — each rep pastes via the size-capped sync fallback.
        let coordinator = FakeHostClipboardDomainCoordinator(
            availability: .needsEnabling, rootToReturn: nil)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
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

        let items = await service.materializeForCopy()
        #expect(items.lazyFiles.map(\.repIndex) == [0, 1])
        #expect(items.droppedReasons.isEmpty)

        // Each pastes via the sync fallback (the File Provider declines): the bytes
        // pull + stage on demand off the main thread.
        let firstURL = await Task.detached { service.copyToMacFileURL(generation: 41, repIndex: 0) }
            .value
        #expect(try Data(contentsOf: #require(firstURL)) == aBytes)
        let secondURL = await Task.detached { service.copyToMacFileURL(generation: 41, repIndex: 1) }
            .value
        #expect(try Data(contentsOf: #require(secondURL)) == bBytes)
        // Each fire consults the File Provider; the declined publish doesn't latch,
        // so the sibling fire retries it.
        #expect(coordinator.publishCallCount == 2)
    }

    @Test("paste-time over-total refusal: the whole plain-file set is refused when the File Provider is unusable")
    func copyPasteTimeRefusesOverTotal() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Availability unprobed at click (`.inactive`) → the advisory does NOT fire,
        // so both reps defer lazily; the paste-time total gate enforces the refusal.
        let coordinator = FakeHostClipboardDomainCoordinator(availability: .inactive, rootToReturn: nil)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        service.start()
        defer { service.stop() }

        let half = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) / 2 + 1
        try guest.send(
            makeOffer(
                generation: 43,
                reps: [
                    (uti: "public.data", byteCount: Int(half), filename: "a.bin", isInline: false),
                    (uti: "public.data", byteCount: Int(half), filename: "b.bin", isInline: false),
                ]))
        try await waitForChange { service.clipboardContent.representations.count == 2 }

        let items = await service.materializeForCopy()
        #expect(items.lazyFiles.map(\.repIndex) == [0, 1])
        #expect(items.droppedReasons.isEmpty)

        // At paste the File Provider is unusable and the sync-bound total is over
        // the cap → each fire refuses (nil), never pasting piecemeal, and no host
        // stream is requested.
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.start()
        #expect(service.copyToMacFileURL(generation: 43, repIndex: 0) == nil)
        #expect(service.copyToMacFileURL(generation: 43, repIndex: 1) == nil)
        #expect(responder.requests.isEmpty)
    }

    @Test("paste-time routing re-check: an unusable File Provider falls back; a later fire re-checks and routes lazily")
    func copyRetriesFileProviderOnLaterFire() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Domain not usable yet — the publish declines, the fire falls back.
        let coordinator = FakeHostClipboardDomainCoordinator(availability: .inactive, rootToReturn: nil)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        service.start()
        defer { service.stop() }

        // Over the deadline cap, so the sync fallback refuses (nil) and the routing
        // isn't latched — the production story: big file + toggle off → refuse;
        // user enables; paste again → lazy route.
        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try guest.send(
            makeOffer(
                generation: 44,
                reps: [
                    (uti: "public.data", byteCount: Int(overCap), filename: "huge.bin", isInline: false)
                ]))
        try await waitForChange {
            service.clipboardContent.representations.first?.isPendingRemote == true
        }

        // `.inactive` at click → deferred, not dropped.
        let items = await service.materializeForCopy()
        #expect(items.lazyFiles.count == 1)

        // First fire: the File Provider declines (unusable) and the single over-cap
        // file is over the total → the sync fallback refuses. The failure isn't
        // latched, so the next fire retries.
        #expect(service.copyToMacFileURL(generation: 44, repIndex: 0) == nil)
        #expect(coordinator.publishCallCount == 1)

        // The domain becomes usable; the next fire re-checks and routes lazily.
        coordinator.availability = .ready
        coordinator.rootToReturn = Self.fakeDomainRoot
        #expect(
            service.copyToMacFileURL(generation: 44, repIndex: 0)
                == Self.fakeDomainRoot.appendingPathComponent("huge.bin"))
        #expect(coordinator.publishCallCount == 2)
    }

    @Test("a superseding offer retracts this service's File Provider offer; same-offer ops don't")
    func supersedingOfferClearsFileProvider() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let coordinator = FakeHostClipboardDomainCoordinator(
            availability: .ready, rootToReturn: Self.fakeDomainRoot)
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", fileProvider: coordinator)
        service.start()
        defer { service.stop() }

        // gen=1: the first offer has nothing to supersede, and building its
        // metadata placeholder must not clear the domain.
        try guest.send(
            makeOffer(
                generation: 1,
                reps: [(uti: "public.data", byteCount: 10, filename: "a.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.count == 1 }
        #expect(coordinator.clearCount == 0)

        // Materializing the SAME offer (no new generation) must not clear either —
        // only a genuine new offer retracts the prior placeholder.
        _ = await service.materializeForCopy()
        #expect(coordinator.clearCount == 0)

        // gen=2 supersedes the live gen=1 promise → clearOffer invoked exactly once,
        // so the stale gen=1 placeholders don't linger in "Kernova Clipboard (Mac)".
        try guest.send(
            makeOffer(
                generation: 2,
                reps: [(uti: "public.data", byteCount: 20, filename: "b.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.filename == "b.bin" }
        #expect(coordinator.clearCount == 1)
    }

    @Test("pullStagedFile for a stale generation returns noCurrentOffer")
    func pullStagedFileStaleGenerationFails() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        try guest.send(
            makeOffer(
                generation: 20,
                reps: [(uti: "public.data", byteCount: 100, filename: "f.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // A pull for a generation that isn't the current offer resolves to
        // noCurrentOffer (the relay maps it to .noSuchItem), without a vsock pull.
        let outcome = await Task.detached {
            service.pullStagedFile(generation: 999, repIndex: 0)
        }.value
        guard case .failure(.noCurrentOffer) = outcome else {
            Issue.record("Expected noCurrentOffer, got \(outcome)")
            return
        }
    }

    @Test("pullStagedFile forwards cumulative byte progress via onProgress (#426)")
    func pullStagedFileForwardsProgress() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test-\(UUID().uuidString)")
        service.start()
        defer { service.stop() }

        // > one 64 KiB chunk so at least one intermediate progress callback fires
        // before the final one carrying bytes == total.
        let fileBytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 40, repIndex: 0, uti: "public.data", bytes: fileBytes,
            filename: "big.bin", isInline: false)
        responder.start()

        try guest.send(
            makeOffer(
                generation: 40,
                reps: [(uti: "public.data", byteCount: fileBytes.count, filename: "big.bin", isInline: false)]))
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let log = ServicingProgressLog()
        let outcome = await Task.detached {
            service.pullStagedFile(
                generation: 40, repIndex: 0, onProgress: { log.record($0, $1) })
        }.value
        guard case .success = outcome else {
            Issue.record("Expected pullStagedFile to succeed, got \(outcome)")
            return
        }

        // The relay forwarded cumulative, non-decreasing progress ending at the
        // total — what drives the extension's determinate download bar.
        #expect(log.count >= 1)
        #expect(log.last?.bytes == UInt64(fileBytes.count))
        #expect(log.last?.total == UInt64(fileBytes.count))
        let byteSequence = log.all.map(\.bytes)
        #expect(byteSequence == byteSequence.sorted())
    }

    @Test(
        "pullStagedFile records the guest→host pull in the window's in-app bar, cleared at the terminal (#426/#354)"
    )
    func pullStagedFileRecordsInAppProgress() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // Reveal instantly so the mid-flight transfer surfaces (the sanctioned
        // "drive the shown path" test value; see VsockClipboardService's doc).
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: .zero)
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

        let pull = Task.detached { service.pullStagedFile(generation: 41, repIndex: 0) }

        // The bar reveals mid-flight: inbound, denominated by the rep's total, and
        // labelled with the filename (#426 — LazyPullSnapshot.filename).
        try await waitForChange { service.transferProgress?.direction == .inbound }
        #expect(service.transferProgress?.totalBytes == fileBytes.count)
        #expect(service.transferProgress?.label == "big.bin")

        // Releasing End resolves the pull; the terminal clears the bar (§13: never
        // leave a stuck bar).
        responder.releaseEnd()
        let outcome = await pull.value
        guard case .success = outcome else {
            Issue.record("Expected pullStagedFile to succeed, got \(outcome)")
            return
        }
        try await waitForChange { service.transferProgress == nil }
    }

    @Test(
        "A control frame arriving while pullStagedFile blocks main does not stall stream-frame routing (#458)"
    )
    func controlFrameDuringBlockingPullDoesNotStallRouting() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A backstop, not the success path: under the fix this resolves in
        // milliseconds via genuine delivery, and under a regression the pull
        // blocks until this fires and resolves to `.pullFailed` — the test fails
        // either way, so the value's size never masks a regression. It must be
        // ≥60 s per docs/TESTING.md's injected-timeout rule: a CI scheduler
        // stall once let a 5 s value fire before the detached responder's
        // genuine delivery, turning the success path into `.pullFailed`.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", lazyPullTimeout: .seconds(60))
        service.start()
        defer { service.stop() }

        // A single lazy-eligible file rep (non-inline, named) — pullStagedFile's target.
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
        // pullStagedFile call below; it is the guest-side analog of the "peer
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

        // The toggle-off paste `provide` callback calls this directly on main — a
        // real synchronous block of the main thread, exactly like production.
        // Under the old `await onControlFrame` code this would hang until the
        // lazyPullTimeout backstop fired and resolved to `.pullFailed`: the
        // interleaved control frame suspends the whole consume loop on the
        // unavailable main actor, so the Begin/Chunk/End behind it in the channel
        // never route and the pull's semaphore never signals. Under the fix, the
        // consume loop dispatches the control frame fire-and-forget and keeps
        // draining — Begin/Chunk/End route immediately regardless of main being
        // blocked — so this resolves promptly.
        let outcome = service.pullStagedFile(generation: 30, repIndex: 0)
        guard case .success(let path) = outcome else {
            Issue.record("Expected pullStagedFile to succeed, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == payload)

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
        // An inline rep so Copy-to-Mac pulls it eagerly (files now defer to the
        // lazy path); beginOnly so the pull parks for the supersede to interrupt.
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

        // Start a copy that issues the gen=1 pull and parks (no End ever arrives).
        let copyTask = Task { await service.materializeForCopy() }
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

        // The superseded copy resolves to nothing materialized for the abandoned
        // offer — no rep was resolved, and no rep was committed.
        let resolved = await copyTask.value
        #expect(resolved.resolvedReps.isEmpty)

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
        // An inline rep so Copy-to-Mac pulls it through the async `materialize`
        // path (which the test seam parks); files now defer to the lazy path.
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

        // Copy issues the gen=1 pull; it completes and parks in the seam.
        let copyTask = Task { await service.materializeForCopy() }
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
        // gen=1's bytes legitimately ride the return value (the guard suppresses
        // the republish, not the return) — assert on the published content only.
        _ = await copyTask.value

        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.uti == "public.png")
        #expect(rep.isPendingRemote)
    }

    @Test("stop() during a SUCCESSFUL pull is suppressed — the gen=1 placeholder is retained, not republished")
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
        // An inline rep so Copy-to-Mac pulls it through the async `materialize`
        // path (which the test seam parks); files now defer to the lazy path.
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

        let copyTask = Task { await service.materializeForCopy() }
        try await entered.wait { didEnter }

        // stop() drops the inbound promise (via dropInboundPromise) but leaves
        // clipboardContent intact — so the resumed guard sees nil !== promise and
        // must NOT republish gen=1's materialized .file rep over the placeholder.
        service.stop()

        released = true
        release.notify()
        _ = await copyTask.value

        // A failed guard would have republished the materialized rep, giving a
        // non-nil fileURL; the placeholder must survive unchanged.
        let rep = try #require(service.clipboardContent.representations.first)
        #expect(rep.isPendingRemote)
        #expect(rep.fileURL == nil)
        #expect(rep.inMemoryData == nil)
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

        // After release, the promise is gone: materializeForCopy resolves nothing
        // new and never requests the rep.
        let resolved = await service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)
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
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        // First caller: preview pull for rep 0. It sends one request and parks
        // (no End arrives). Run it detached so the test keeps driving.
        let previewTask = Task { await service.materializeForPreview() }

        // Wait until EXACTLY one request for rep 0 has been recorded — the
        // in-flight window we want the Copy caller to coalesce into.
        let rep0XID = inboundTransferID(generation: generation, repIndex: 0)
        try await responder.answered.wait {
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
        #expect(copyContent.resolvedReps.count == 1)
        #expect(copyContent.resolvedReps.first?.inMemoryData == payload)

        // With the cache now settled (no in-flight pull), a fresh Copy-to-Mac
        // resolves the rep from the cache without re-requesting it.
        let settledCopy = await service.materializeForCopy()
        #expect(responder.requests.filter { $0.transferID == rep0XID }.count == 1)
        #expect(settledCopy.resolvedReps.count == 1)
        #expect(settledCopy.resolvedReps.first?.inMemoryData == payload)
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

        // Copy issues the pull; with no answer and the channel open, it must
        // resolve (not hang) once the backstop fires — dropping the un-pulled rep.
        let resolved = await service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)

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
        let resolved = await service.materializeForCopy()
        #expect(ClipboardContent(representations: resolved.resolvedReps).text == "my edit")
        #expect(resolved.resolvedReps.allSatisfy { !$0.isPendingRemote })
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
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

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
        try await waitForChange { service.lastTransferIssue != nil }

        #expect(service.clipboardContent.isEmpty)
        // No promise is held: Copy-to-Mac resolves nothing and sends no request
        // (mirrors the guest agent's all-skip handling, not a dangling promise).
        let resolved = await service.materializeForCopy()
        #expect(resolved.resolvedReps.isEmpty)
        #expect(resolved.lazyFiles.isEmpty)
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
        // host's own mid-stream disk-full detection drives via deliverAbort). A
        // directory rep is used because Copy-to-Mac still pulls those eagerly
        // through the async `pull` (plain files now defer to the lazy path, which
        // surfaces failures through the File Provider, not `lastTransferIssue`).
        let responder = FakeGuestResponder(guest: guest)
        defer { responder.cancel() }
        responder.register(
            generation: 5, repIndex: 0, uti: UTType.folder.identifier, bytes: Data(count: 4096),
            filename: "BigFolder", isInline: false, beginOnly: true)
        responder.start()

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = 5
            $0.repInfo = [
                Kernova_V1_ClipboardRepresentationInfo.with {
                    $0.uti = UTType.folder.identifier
                    $0.byteCount = 4096
                    $0.filename = "BigFolder"
                    $0.isInline = false
                    $0.isDirectory = true
                }
            ]
        }
        try guest.send(offer)
        try await waitForChange { service.clipboardContent.representations.first?.isPendingRemote == true }

        let copyTask = Task { await service.materializeForCopy() }
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

        _ = await copyTask.value
        try await waitForChange {
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
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: .zero)
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

        let copyTask = Task { await service.materializeForCopy() }

        // Chunks have landed but End is held → the bar shows, inbound.
        try await waitForChange { service.transferProgress?.direction == .inbound }
        #expect(service.transferProgress?.totalBytes == bytes.count)
        #expect((service.transferProgress?.bytesTransferred ?? 0) > 0)

        responder.releaseEnd()
        _ = await copyTask.value
        try await waitForChange { service.transferProgress == nil }
    }

    @Test("an outbound transfer sets transferProgress while streaming and clears it on completion")
    func outboundTransferProgressSetThenCleared() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: .zero)
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
        try await waitForChange { service.transferProgress?.direction == .outbound }
        #expect(service.transferProgress?.totalBytes == expected.count)
        #expect((service.transferProgress?.bytesTransferred ?? 0) > 0)

        // Open the window fully → the rest streams and the transfer completes.
        try sendAck(from: guest, transferID: xid, bytesConsumed: 0, windowBytes: 2 * 1024 * 1024)
        try await waitForChange { service.transferProgress == nil }
    }

    @Test("a transfer that finishes before the reveal delay never shows progress")
    func transferBelowRevealDelayNeverShows() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        // A reveal delay long enough that the fast transfer completes first.
        let service = VsockClipboardService(
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: .seconds(3600))
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
            channel: host, label: "test-\(UUID().uuidString)", progressRevealDelay: .zero)
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
        let copyTask = Task { await service.materializeForCopy() }
        try await waitForChange { service.transferProgress != nil }

        service.stop()
        #expect(service.transferProgress == nil)

        responder.releaseEnd()
        _ = await copyTask.value
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

    /// The lazy file items (the File-Provider-off paste fallback), by offer
    /// coordinates.
    fileprivate var lazyFiles: [(generation: UInt64, repIndex: Int, uti: String, filename: String)] {
        compactMap {
            switch $0 {
            case .lazyFile(let generation, let repIndex, let uti, let filename):
                (generation, repIndex, uti, filename)
            default:
                nil
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

/// Records the service's host File Provider coordinator calls and returns canned
/// URLs, so paste-time routing and the copy-click advisory can be asserted
/// without a live domain — the host analog of the guest's `FakeFileProviderPublisher`.
///
/// `@MainActor` matching the protocol: every call arrives on the main actor (the
/// service invokes it there, and `copyToMacFileURL`'s thread-hop re-enters main),
/// so the recorded state needs no lock.
@MainActor
final class FakeHostClipboardDomainCoordinator: HostClipboardDomainCoordinating {
    struct Published: Equatable {
        let generation: UInt64
        let repIndex: Int
        let filename: String
        let byteCount: UInt64
        let uti: String
    }

    var availability: FileProviderAvailability
    /// The domain root `publishItemsForPaste` builds its returned URLs under.
    ///
    /// `nil` models an unusable File Provider (the publish declines, callers fall
    /// back). Mutable so a test can model the domain becoming usable between two
    /// paste fires — the paste-time re-check that replaced the #429 re-publish.
    var rootToReturn: URL?

    private(set) var published: [Published] = []
    private(set) var publishedFolders: [FileProviderPublishFolder] = []
    private(set) var publishCallCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var clearCount = 0
    private(set) var prepareCount = 0

    init(availability: FileProviderAvailability = .inactive, rootToReturn: URL? = nil) {
        self.availability = availability
        self.rootToReturn = rootToReturn
    }

    func serviceDidStart() { startCount += 1 }
    func serviceDidStop(_ source: any HostClipboardFileRepProviding) { stopCount += 1 }
    func prepareForCopy() { prepareCount += 1 }

    func publishItemsForPaste(
        source: any HostClipboardFileRepProviding, generation: UInt64,
        items: [FileProviderPublishItem], folders: [FileProviderPublishFolder]
    ) -> [Int: URL]? {
        publishCallCount += 1
        published.append(
            contentsOf: items.map {
                Published(
                    generation: generation, repIndex: $0.repIndex, filename: $0.filename,
                    byteCount: $0.byteCount, uti: $0.uti)
            })
        publishedFolders.append(contentsOf: folders)
        guard let root = rootToReturn else { return nil }
        var urls: [Int: URL] = [:]
        for item in items { urls[item.repIndex] = root.appendingPathComponent(item.filename) }
        for folder in folders { urls[folder.repIndex] = root.appendingPathComponent(folder.filename) }
        return urls
    }

    func clearOffer(from source: any HostClipboardFileRepProviding) { clearCount += 1 }
}
