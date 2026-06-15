import Testing
import Foundation
import Darwin
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

    /// Legacy-shaped offer: `formats` only, no `utis` — what a pre-UTI peer sends.
    private func makeOffer(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.formats = [.textUtf8]
        }
        return frame
    }

    /// UTI-capable offer.
    private func makeOffer(generation: UInt64, utis: [String]) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.utis = utis
        }
        return frame
    }

    /// Legacy-shaped data: `format` + `data`, no `representations`.
    private func makeData(generation: UInt64, text: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = generation
            $0.format = .textUtf8
            $0.data = Data(text.utf8)
        }
        return frame
    }

    /// UTI-tagged data.
    private func makeData(
        generation: UInt64, representations: [(uti: String, data: Data)]
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = generation
            $0.representations = representations.map { representation in
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = representation.uti
                    $0.data = representation.data
                }
            }
        }
        return frame
    }

    /// Legacy-shaped request: `format` only, no `utis` — what a pre-UTI peer sends.
    private func makeRequest(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.format = .textUtf8
        }
        return frame
    }

    /// UTI-capable request.
    private func makeRequest(generation: UInt64, utis: [String]) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.utis = utis
        }
        return frame
    }

    // MARK: - Tests

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

        let service = VsockClipboardService(channel: host, label: "test")
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

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        // The clipboard listener accepts the connection before the service is
        // constructed, so connectivity is equivalent to "started and not yet
        // stopped". Liveness lives on the control channel.
        #expect(service.isConnected)
    }

    @Test("grabIfChanged sends ClipboardOffer with monotonic generation")
    func grabSendsOffer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "first")
        service.grabIfChanged()
        let firstOffer = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offerA) = firstOffer.payload else {
            Issue.record("Expected first clipboardOffer, got \(String(describing: firstOffer.payload))")
            return
        }
        #expect(offerA.formats.contains(.textUtf8))
        #expect(offerA.utis == [ClipboardContent.utf8TextUTI])

        service.clipboardContent = ClipboardContent(text: "second")
        service.grabIfChanged()
        let secondOffer = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offerB) = secondOffer.payload else {
            Issue.record("Expected second clipboardOffer, got \(String(describing: secondOffer.payload))")
            return
        }
        #expect(offerB.generation > offerA.generation)
    }

    @Test("grabIfChanged is suppressed when text is unchanged or empty")
    func grabSuppressionGuards() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // No startup Hello on the clipboard channel — that lives on the
        // control channel now. The recorder starts empty.

        // Empty text → no offer.
        var snapshot = recorder.frames.count
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: snapshot)

        // First non-empty text → exactly one offer.
        service.clipboardContent = ClipboardContent(text: "alpha")
        service.grabIfChanged()
        try await waitForFrameCount(recorder, equals: snapshot + 1)
        let alphaFrame = recorder.frames[snapshot]
        guard case .clipboardOffer = alphaFrame.payload else {
            Issue.record("Expected clipboardOffer for 'alpha', got \(String(describing: alphaFrame.payload))")
            return
        }
        snapshot = recorder.frames.count

        // Same text → no second offer.
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: snapshot)

        // Fresh text → another offer.
        service.clipboardContent = ClipboardContent(text: "beta")
        service.grabIfChanged()
        try await waitForFrameCount(recorder, equals: snapshot + 1)
        let betaFrame = recorder.frames[snapshot]
        guard case .clipboardOffer = betaFrame.payload else {
            Issue.record("Expected clipboardOffer for 'beta', got \(String(describing: betaFrame.payload))")
            return
        }
    }

    @Test("Responds to ClipboardRequest with matching generation")
    func respondsToMatchingRequest() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "payload")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected offer, got \(String(describing: offerFrame.payload))")
            return
        }

        try guest.send(makeRequest(generation: offer.generation))
        let dataFrame = try await nextFrame(from: guest)
        guard case .clipboardData(let data) = dataFrame.payload else {
            Issue.record("Expected clipboardData, got \(String(describing: dataFrame.payload))")
            return
        }
        #expect(data.generation == offer.generation)
        #expect(data.format == .textUtf8)
        #expect(String(data: data.data, encoding: .utf8) == "payload")
    }

    @Test("Stale ClipboardRequest is ignored")
    func ignoresStaleRequest() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "payload")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected offer, got \(String(describing: offerFrame.payload))")
            return
        }

        // Request a generation that doesn't match the pending offer.
        try guest.send(makeRequest(generation: offer.generation &+ 1_000))

        // Send a real request shortly after; the *real* response is what
        // should arrive next on the guest side, proving the stale one was
        // dropped rather than queued ahead of it.
        try guest.send(makeRequest(generation: offer.generation))
        let response = try await nextFrame(from: guest)
        guard case .clipboardData(let data) = response.payload else {
            Issue.record("Expected clipboardData, got \(String(describing: response.payload))")
            return
        }
        #expect(data.generation == offer.generation)
    }

    @Test("handleRequest with unsupported format replies with an Error frame")
    func unsupportedFormatRepliesWithError() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "host content")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }

        var badRequest = Frame()
        badRequest.protocolVersion = 1
        badRequest.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .unspecified  // any non-textUtf8 value
        }
        try guest.send(badRequest)

        // Expect an Error frame — not silence.
        let response = try await nextFrame(from: guest)
        guard case .error(let err) = response.payload else {
            Issue.record("Expected error frame, got \(String(describing: response.payload))")
            return
        }
        #expect(err.code == "clipboard.format.unavailable")
        #expect(err.inReplyTo == "clipboard.request")
        #expect(err.message.contains("gen=\(offer.generation)"))
    }

    @Test("handleRequest data-send failure is logged without crashing and leaves service connected")
    func dataSendFailureIsHandledGracefully() async throws {
        let (hostFd, _, host, guest) = try makeRawPair()
        host.start()
        guest.start()

        // SO_NOSIGPIPE on the host channel's fd so a write to a peer-closed
        // socket surfaces as an error rather than delivering SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(hostFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(text: "host data")
        service.grabIfChanged()
        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }

        // Queue the request in the kernel buffer, then close the guest end so
        // the service's data-send reply arrives at a dead peer.
        try guest.send(makeRequest(generation: offer.generation))
        guest.close()

        // The service reads the request, tries to send data, fails (peer gone),
        // logs .error, and attempts a best-effort error frame (also fails,
        // swallowed). The service must not crash (no SIGPIPE) and isConnected
        // must remain true because only stop() clears it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.isConnected, "isConnected should remain true — only stop() clears it")
    }

    @Test("Legacy inbound offer triggers a legacy request and incoming data updates clipboardContent")
    func inboundFlowPopulatesClipboard() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 42))
        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        #expect(req.generation == 42)
        // A legacy offer must be answered with a legacy-shaped request so the
        // pre-UTI peer understands it.
        #expect(req.utis.isEmpty)
        #expect(req.format == .textUtf8)

        try guest.send(makeData(generation: 42, text: "from guest"))
        try await waitUntil { service.clipboardContent.text == "from guest" }
        #expect(service.clipboardContent.text == "from guest")
    }

    @Test("Frames with unsupported protocol version are dropped before payload dispatch")
    func dropsUnsupportedProtocolVersion() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        // Send a ClipboardOffer with the wrong protocol_version. If the
        // version check is missing, the service would respond with a
        // ClipboardRequest. With the check in place, the frame is dropped.
        var offerV99 = Frame()
        offerV99.protocolVersion = 99
        offerV99.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = 1
            $0.formats = [.textUtf8]
        }
        try guest.send(offerV99)

        // Follow with a v1 ClipboardOffer using a different generation. The
        // service must request only gen=2 — proof that gen=1 was dropped.
        try guest.send(makeOffer(generation: 2))

        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        #expect(req.generation == 2)
    }

    @Test("handleOffer send failure leaves pendingInboundGeneration unchanged")
    func offerSendFailureDoesNotSetPendingGeneration() async throws {
        let (guestRawFd, hostRawFd) = try makeRawSocketPair()

        // SO_NOSIGPIPE so the service's write to a closed peer surfaces as an
        // error rather than killing the test process with SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(hostRawFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let guest = VsockChannel(fileDescriptor: guestRawFd)
        let host = VsockChannel(fileDescriptor: hostRawFd)
        guest.start()
        host.start()

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        // No Hello traffic on this channel — control-plane responsibilities
        // moved to `VsockControlService`. Start recording frames that arrive
        // on guest BEFORE closing it.
        // The recorder captures any ClipboardRequest the service might send —
        // if the bug were present, a request for gen=42 would arrive here.
        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        // Push the offer into the kernel buffer then close the guest channel.
        // The service reads the offer; its attempt to send a ClipboardRequest
        // back fails (peer is gone), so handleOffer's catch path runs without
        // committing pendingInboundGeneration.
        try guest.send(makeOffer(generation: 42))
        guest.close()

        // Sleep briefly to allow the consume task to drain the offer from the
        // socket buffer and dispatch handleOffer to the main actor. Then flush
        // any pending main-actor work before reading the seam. All three steps
        // (consume task reads frame, dispatches to main actor, main actor runs
        // handleOffer) are triggered by this yield sequence.
        try await Task.sleep(for: .milliseconds(150))

        // The fix: pendingInboundGeneration must NOT be set to 42 — state is
        // only committed inside the do-block after a successful send.
        // With the bug present this would equal 42.
        #expect(service.pendingInboundGenerationForTesting == nil)

        // Corroborating assertion: no ClipboardRequest frame arrived, because
        // the send that would have produced it failed.
        if recorder.frames.contains(where: {
            if case .clipboardRequest(let r) = $0.payload { return r.generation == 42 }
            return false
        }) {
            Issue.record(
                "Service sent a ClipboardRequest despite send failure — pendingInboundGeneration would be stale")
        }
    }

    @Test("ClipboardData with stale generation is ignored")
    func ignoresStaleData() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 1))
        _ = try await nextFrame(from: guest)  // request for gen=1

        try guest.send(makeOffer(generation: 2))
        _ = try await nextFrame(from: guest)  // request for gen=2

        // Reply for the first (now stale) offer — must be dropped.
        try guest.send(makeData(generation: 1, text: "stale"))
        // Then deliver the real one.
        try guest.send(makeData(generation: 2, text: "fresh"))

        try await waitUntil { service.clipboardContent.text == "fresh" }
        #expect(service.clipboardContent.text == "fresh")
    }

    // MARK: - UTI representations

    @Test("Multi-representation grab offers ordered UTIs plus the legacy text format")
    func multiRepGrabOffersUTIsAndLegacyFormat() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.rtf", data: Data("{\\rtf1}".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
        ])
        service.grabIfChanged()

        let frame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = frame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: frame.payload))")
            return
        }
        #expect(offer.utis == ["public.rtf", ClipboardContent.utf8TextUTI])
        #expect(offer.formats == [.textUtf8])
    }

    @Test("Image-only grab offers UTIs without the legacy text format")
    func imageOnlyGrabOmitsLegacyFormat() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        ])
        service.grabIfChanged()

        let frame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = frame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: frame.payload))")
            return
        }
        #expect(offer.utis == ["public.png"])
        #expect(offer.formats.isEmpty)
    }

    @Test("UTI request returns the requested representations in content order")
    func utiRequestReturnsRepresentations() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.rtf", data: Data("{\\rtf1}".utf8)),
            .init(uti: ClipboardContent.utf8TextUTI, data: Data("plain".utf8)),
            .init(uti: "public.png", data: pngBytes),
        ])
        service.grabIfChanged()

        let offerFrame = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            Issue.record("Expected clipboardOffer, got \(String(describing: offerFrame.payload))")
            return
        }

        // Request a subset, deliberately in reverse order — the reply must
        // preserve *content* order, not request order.
        try guest.send(makeRequest(generation: offer.generation, utis: ["public.png", "public.rtf"]))

        let dataFrame = try await nextFrame(from: guest)
        guard case .clipboardData(let data) = dataFrame.payload else {
            Issue.record("Expected clipboardData, got \(String(describing: dataFrame.payload))")
            return
        }
        #expect(data.generation == offer.generation)
        #expect(data.representations.map(\.uti) == ["public.rtf", "public.png"])
        #expect(data.representations.last?.data == pngBytes)
        // The legacy pair stays empty on the UTI path.
        #expect(data.data.isEmpty)
    }

    @Test("UTI-capable inbound offer is requested by UTIs and representations populate clipboardContent")
    func utiInboundFlowPopulatesClipboard() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 7, utis: ["public.png", ClipboardContent.utf8TextUTI]))
        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        #expect(req.generation == 7)
        #expect(req.utis == ["public.png", ClipboardContent.utf8TextUTI])

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        try guest.send(
            makeData(
                generation: 7,
                representations: [
                    (uti: "public.png", data: pngBytes),
                    (uti: ClipboardContent.utf8TextUTI, data: Data("caption".utf8)),
                ]))

        try await waitUntil { !service.clipboardContent.isEmpty }
        #expect(
            service.clipboardContent.representations.map(\.uti) == [
                "public.png", ClipboardContent.utf8TextUTI,
            ])
        #expect(service.clipboardContent.representations.first?.data == pngBytes)
        #expect(service.clipboardContent.text == "caption")
    }

    @Test("Inbound representation filename is buffered for a later Copy to Mac")
    func inboundFilenameBuffered() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 9, utis: ["public.png"]))
        _ = try await nextFrame(from: guest)  // request

        var data = Frame()
        data.protocolVersion = 1
        data.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = 9
            $0.representations = [
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = "public.png"
                    $0.data = Data([0x89, 0x50])
                    $0.filename = "from-guest.png"
                }
            ]
        }
        try guest.send(data)

        try await waitUntil { !service.clipboardContent.isEmpty }
        // The host doesn't write the pasteboard here (that's "Copy to Mac"),
        // but the filename must survive in the buffer so copyToMac can stage it.
        #expect(service.clipboardContent.representations.first?.filename == "from-guest.png")
    }

    @Test("Inbound representations are sanitized — file references never reach the buffer")
    func inboundRepresentationsSanitized() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 5, utis: ["public.png", "public.file-url"]))
        _ = try await nextFrame(from: guest)  // request

        let pngBytes = Data([0x89, 0x50])
        try guest.send(
            makeData(
                generation: 5,
                representations: [
                    (uti: "public.file-url", data: Data("file:///etc/passwd".utf8)),
                    (uti: "public.png", data: pngBytes),
                ]))

        try await waitUntil { !service.clipboardContent.isEmpty }
        #expect(service.clipboardContent.representations.map(\.uti) == ["public.png"])
    }

    @Test("Inbound data with only forbidden representations is ignored and consumes the generation")
    func inboundAllForbiddenIgnored() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 6, utis: ["public.file-url"]))
        _ = try await nextFrame(from: guest)  // request

        try guest.send(
            makeData(
                generation: 6,
                representations: [
                    (uti: "public.file-url", data: Data("file:///x".utf8))
                ]))

        // The unusable payload must not land in the buffer, and the pending
        // generation must be consumed rather than left latched.
        try await waitUntil { service.pendingInboundGenerationForTesting == nil }
        #expect(service.clipboardContent.isEmpty)
    }

    @Test("Oversized content surfaces the issue once, not on every grab")
    func oversizedIssueFiresOnce() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.tiff", data: Data(count: ClipboardSnapshotPolicy.maxTotalByteCount + 1))
        ])
        service.grabIfChanged()
        let firstIssue = service.lastTransferIssue
        #expect(firstIssue != nil)

        // Same content re-grabbed (window blur) — no new frame, no re-fired issue.
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: 0)
        #expect(service.lastTransferIssue == firstIssue)
    }

    @Test("Inbound data resets dedup so re-grabbing the same content re-offers")
    func inboundDataResetsDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        try guest.send(makeOffer(generation: 1))
        _ = try await nextFrame(from: guest)  // request for gen=1
        try guest.send(makeData(generation: 1, text: "round-trip"))
        try await waitUntil { service.clipboardContent.text == "round-trip" }

        // Content unchanged since the inbound update; a grab must still offer
        // (otherwise round-tripped content silently stops syncing back).
        service.grabIfChanged()
        let frame = try await nextFrame(from: guest)
        guard case .clipboardOffer = frame.payload else {
            Issue.record("Expected clipboardOffer after round-trip, got \(String(describing: frame.payload))")
            return
        }
    }

    @Test("clearBuffer empties and resets dedup so re-grabbing the same content re-offers")
    func clearBufferResetsDedup() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
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

    @Test("Inbound empty legacy text is dropped without wiping the buffer")
    func inboundEmptyLegacyTextPreservesBuffer() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        // Seed a non-empty buffer that a malformed inbound frame must not wipe.
        service.clipboardContent = ClipboardContent(text: "existing")

        try guest.send(makeOffer(generation: 7))
        _ = try await nextFrame(from: guest)  // request for gen=7
        // A non-conformant peer sends an empty legacy-text payload.
        try guest.send(makeData(generation: 7, text: ""))

        // The generation is consumed, but the buffer is preserved (not wiped).
        try await waitUntil { service.pendingInboundGenerationForTesting == nil }
        #expect(service.clipboardContent.text == "existing")
    }

    @Test("Oversized content refuses the offer and surfaces a contentTooLarge issue")
    func oversizedContentSurfacesIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        let recorder = FrameRecorder(channel: guest)
        defer { recorder.cancel() }

        let oversize = ClipboardSnapshotPolicy.maxTotalByteCount + 1
        service.clipboardContent = ClipboardContent(representations: [
            .init(uti: "public.tiff", data: Data(count: oversize))
        ])
        service.grabIfChanged()

        try await expectNoNewFrames(on: recorder, sinceCount: 0)
        guard case .contentTooLarge(let byteCount, let limit) = service.lastTransferIssue?.kind
        else {
            Issue.record("Expected contentTooLarge issue, got \(String(describing: service.lastTransferIssue))")
            return
        }
        #expect(byteCount == oversize)
        #expect(limit == ClipboardSnapshotPolicy.maxTotalByteCount)
    }

    @Test("Peer clipboard error frame surfaces as a peerReportedError issue")
    func peerErrorSurfacesAsIssue() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
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
