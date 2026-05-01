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
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (VsockChannel(fileDescriptor: fds[0]),
                VsockChannel(fileDescriptor: fds[1]))
    }

    /// Drains the next frame from a channel within a generous deadline. Tests
    /// that expect no frame must use `expectNoFrame` instead — this helper
    /// throws on timeout.
    private func nextFrame(
        from channel: VsockChannel,
        timeout: Duration = .seconds(2)
    ) async throws -> Frame {
        let receiver = Task<Frame?, Error> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            receiver.cancel()
        }
        defer { timeoutTask.cancel() }
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame")
        }
        return frame
    }

    private struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// MainActor-isolated buffer fed by a single iterator on the channel.
    /// Tests that need both "expect frame" and "expect no frame" assertions
    /// against the same channel must not hand-roll iterators per call —
    /// `AsyncThrowingStream` is single-consumer and cancelling an iterator
    /// terminates the shared iteration, poisoning subsequent reads.
    @MainActor
    private final class FrameRecorder {
        var frames: [Frame] = []
        private var consumeTask: Task<Void, Never>?

        init(channel: VsockChannel) {
            consumeTask = Task { @MainActor [weak self] in
                do {
                    for try await frame in channel.incoming {
                        self?.frames.append(frame)
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

    /// Spins until `recorder.frames.count == expected`, or fails the test if
    /// the deadline elapses.
    private func waitForFrameCount(
        _ recorder: FrameRecorder,
        equals expected: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            recorder.frames.count == expected
        }
    }

    /// Sleeps `duration` then asserts no frames arrived since `before`.
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
            Issue.record("Expected no new frames over \(duration); got \(extras.count): \(extras.map { String(describing: $0.payload) })")
        }
    }

    /// Spins until a service-side condition is true (or a deadline elapses).
    /// Replaces ad-hoc `Task.sleep` waits in concurrency-sensitive tests.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !predicate() {
            throw TestFailure("Predicate did not become true within \(timeout)")
        }
    }

    /// Builds the guest-side hello frame the service expects in order to
    /// flip `isConnected` true.
    private func makeHello() -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["clipboard.text.utf8"]
        }
        return frame
    }

    private func makeOffer(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.formats = [.textUtf8]
        }
        return frame
    }

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

    private func makeRequest(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.format = .textUtf8
        }
        return frame
    }

    // MARK: - Tests

    @Test("Sends Hello frame on start")
    func sendsHelloOnStart() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        let received = try await nextFrame(from: guest)
        guard case .hello(let hello) = received.payload else {
            Issue.record("Expected hello payload, got \(String(describing: received.payload))")
            return
        }
        #expect(hello.capabilities.contains("clipboard.text.utf8"))
    }

    @Test("Guest hello flips isConnected to true")
    func helloFlipsConnected() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        // Discard our outbound hello.
        _ = try await nextFrame(from: guest)
        try guest.send(makeHello())

        try await waitUntil { service.isConnected }
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

        _ = try await nextFrame(from: guest)        // host hello
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        service.clipboardText = "first"
        service.grabIfChanged()
        let firstOffer = try await nextFrame(from: guest)
        guard case .clipboardOffer(let offerA) = firstOffer.payload else {
            Issue.record("Expected first clipboardOffer, got \(String(describing: firstOffer.payload))")
            return
        }
        #expect(offerA.formats.contains(.textUtf8))

        service.clipboardText = "second"
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

        // Frame 0: host's startup Hello.
        try await waitForFrameCount(recorder, equals: 1)

        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        // Empty text → no offer.
        var snapshot = recorder.frames.count
        service.grabIfChanged()
        try await expectNoNewFrames(on: recorder, sinceCount: snapshot)

        // First non-empty text → exactly one offer.
        service.clipboardText = "alpha"
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
        service.clipboardText = "beta"
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

        _ = try await nextFrame(from: guest)        // host hello
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        service.clipboardText = "payload"
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

        _ = try await nextFrame(from: guest)        // host hello
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        service.clipboardText = "payload"
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

    @Test("Inbound offer triggers a request and incoming data updates clipboardText")
    func inboundFlowPopulatesClipboard() async throws {
        let (guest, host) = try makePair()
        guest.start()
        host.start()
        defer { guest.close() }

        let service = VsockClipboardService(channel: host, label: "test")
        service.start()
        defer { service.stop() }

        _ = try await nextFrame(from: guest)        // host hello
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        try guest.send(makeOffer(generation: 42))
        let request = try await nextFrame(from: guest)
        guard case .clipboardRequest(let req) = request.payload else {
            Issue.record("Expected clipboardRequest, got \(String(describing: request.payload))")
            return
        }
        #expect(req.generation == 42)

        try guest.send(makeData(generation: 42, text: "from guest"))
        try await waitUntil { service.clipboardText == "from guest" }
        #expect(service.clipboardText == "from guest")
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

        _ = try await nextFrame(from: guest)        // host hello

        // Send a Hello with the wrong protocol_version. If the version check
        // is missing, isConnected would flip true (Hello payload otherwise
        // looks fine). With the check in place, the frame is dropped.
        var hello = Frame()
        hello.protocolVersion = 99
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["clipboard.text.utf8"]
        }
        try guest.send(hello)

        // Follow with a real Hello to give the consume loop something to
        // observe; once that lands, the v99 Hello has already been processed.
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        #expect(service.isConnected)  // tripped only by the v1 Hello
    }

    @Test("handleOffer send failure leaves pendingInboundGeneration unchanged")
    func offerSendFailureDoesNotSetPendingGeneration() async throws {
        var rawFds: [Int32] = [-1, -1]
        let rc = rawFds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let (guestRawFd, hostRawFd) = (rawFds[0], rawFds[1])

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

        // Discard host's outbound Hello, then connect as guest.
        _ = try await nextFrame(from: guest)
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        // Start recording frames that arrive on guest BEFORE closing it.
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
            Issue.record("Service sent a ClipboardRequest despite send failure — pendingInboundGeneration would be stale")
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

        _ = try await nextFrame(from: guest)        // host hello
        try guest.send(makeHello())
        try await waitUntil { service.isConnected }

        try guest.send(makeOffer(generation: 1))
        _ = try await nextFrame(from: guest)         // request for gen=1

        try guest.send(makeOffer(generation: 2))
        _ = try await nextFrame(from: guest)         // request for gen=2

        // Reply for the first (now stale) offer — must be dropped.
        try guest.send(makeData(generation: 1, text: "stale"))
        // Then deliver the real one.
        try guest.send(makeData(generation: 2, text: "fresh"))

        try await waitUntil { service.clipboardText == "fresh" }
        #expect(service.clipboardText == "fresh")
    }
}

