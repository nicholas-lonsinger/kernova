import Testing
import Foundation
import AppKit
import Darwin
import KernovaProtocol

// MARK: - Fake Pasteboard

/// In-memory `Pasteboard` substitute. Thread-safe via NSLock so tests running
/// on DispatchQueue.main don't race the setup thread.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var _changeCount: Int = 0
    private var _contents: [NSPasteboard.PasteboardType: String] = [:]
    private var _setStringFailureCount: Int = 0

    var changeCount: Int {
        lock.withLock { _changeCount }
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        lock.withLock { _contents[type] }
    }

    /// Make the next `n` `setString` calls return `false` and skip storage
    /// updates. Lets tests model OS-level pasteboard write failures.
    func failNextSetString(times: Int = 1) {
        lock.withLock { _setStringFailureCount += times }
    }

    @discardableResult
    func clearContents() -> Int {
        // Real NSPasteboard.clearContents() bumps the change count and returns
        // the new value. Mirror that behavior so the fake's echo-suppression
        // delta matches a real pasteboard.
        lock.withLock {
            _contents.removeAll()
            _changeCount += 1
            return _changeCount
        }
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        lock.withLock {
            if _setStringFailureCount > 0 {
                _setStringFailureCount -= 1
                return false
            }
            _contents[type] = string
            _changeCount += 1
            return true
        }
    }
}

// MARK: - Test Suite

@Suite("VsockGuestClipboardAgent state machine")
struct VsockGuestClipboardAgentTests {

    // MARK: - Agent factory helpers

    /// Sets up an agent with the given pasteboard and a socket provider that
    /// returns the given fd on first call, transient failure thereafter. Does
    /// NOT retry (long retry interval) so tests don't interfere with each other.
    private func makeAgent(pasteboard: FakePasteboard, agentFd: Int32) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-test",
            retryInterval: .seconds(60)
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
    }

    /// Starts the agent and waits until the host side receives the Hello frame,
    /// then replies with a Hello so the agent transitions to "connected" state.
    private func startAgentAndWaitForHello(
        agent: VsockGuestClipboardAgent,
        hostChannel: VsockChannel
    ) async throws {
        agent.start()
        let hello = try await nextFrame(from: hostChannel)
        guard case .hello = hello.payload else {
            throw TestFailure("Expected Hello from agent, got \(String(describing: hello.payload))")
        }
        try hostChannel.send(makeHelloFrame())
        // Wait until liveChannel is set on the main queue before returning,
        // so callers driving checkClipboardChange() see a non-nil channel.
        try await waitUntil { agent.liveChannelForTesting != nil }
    }

    // MARK: - Tests

    @Test("outbound offer is sent when local pasteboard changes")
    func outboundOfferOnPasteboardChange() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        pasteboard.setString("hello from guest", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(offer.formats.contains(.textUtf8))
        #expect(offer.generation >= 1)
    }

    @Test("echo suppression — text just written from host is not re-offered")
    func echoSuppression() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Host sends offer → agent requests → host sends data → agent writes pasteboard
        try hostChannel.send(makeOfferFrame(generation: 1))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        #expect(req.generation == 1)

        try hostChannel.send(makeDataFrame(generation: 1, text: "from host"))

        try await waitUntil { pasteboard.string(forType: .string) == "from host" }
        #expect(pasteboard.string(forType: .string) == "from host")

        // Poll — since we just received "from host", no re-offer should be sent
        await MainActor.run { agent.checkClipboardChange() }

        // Give a window; no offer should arrive. Use a short-lived task and cancel it.
        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        let extra = await extraTask.value
        if let frame = extra, case .clipboardOffer = frame.payload {
            throw TestFailure("Echo suppression failed: agent re-offered host-written text")
        }
    }

    @Test("reconnect resets lastSeenText so agent re-offers current pasteboard")
    func reconnectResetsLastSeenText() async throws {
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
            if let fd = fdBox.fd(at: n - 1) {
                return .success(fd)
            } else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()

        // First connection: consume Hello
        let hello1 = try await nextFrame(from: host0)
        guard case .hello = hello1.payload else {
            throw TestFailure("Expected Hello on first connection")
        }
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

        // Wait for second connection Hello
        let hello2 = try await nextFrame(from: host1, timeout: .seconds(3))
        guard case .hello = hello2.payload else {
            throw TestFailure("Expected Hello on second connection")
        }
        try await waitUntil { agent.liveChannelForTesting != nil }

        // After reconnect, lastSeenText is cleared — next poll should re-offer
        await MainActor.run { agent.checkClipboardChange() }

        let offer2Frame = try await nextFrame(from: host1)
        guard case .clipboardOffer(let offer2) = offer2Frame.payload else {
            throw TestFailure("Expected ClipboardOffer after reconnect")
        }
        #expect(offer2.generation > offer1.generation)
    }

    @Test("stale ClipboardData with wrong generation is dropped")
    func staleClipboardDataDropped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        try hostChannel.send(makeOfferFrame(generation: 5))
        _ = try await nextFrame(from: hostChannel)  // Consume agent's request

        // Send data with wrong generation (4 instead of 5)
        try hostChannel.send(makeDataFrame(generation: 4, text: "stale data"))

        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("Hello send failure aborts serve without publishing liveChannel; client retries")
    func helloFailureAbortsAndRetries() async throws {
        let pasteboard = FakePasteboard()

        // First attempt: close the peer fd before the agent writes Hello so the
        // first send() hits EPIPE / .closed. Second attempt: a healthy pair.
        let (agentFd0, remoteFd0) = try makeRawSocketPair()

        // SO_NOSIGPIPE so writing to a peer-closed socket surfaces as an
        // error rather than killing the test process with SIGPIPE.
        var noSigpipe: Int32 = 1
        _ = setsockopt(agentFd0, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        close(remoteFd0)  // peer gone before agent writes Hello

        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host1.start()
        defer { host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        // Gate: signals when the reconnect loop asks for the second fd (i.e.,
        // after the first connection has already failed and been cleaned up).
        let firstFailedGate = DispatchSemaphore(value: 0)
        // Gate: released by the test body after it has asserted liveChannel==nil,
        // allowing the reconnect loop to continue with the healthy fd.
        let secondProvideGate = DispatchSemaphore(value: 0)

        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-hello-fail-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            if n == 2 {
                // The reconnect loop has already (a) called serve with fd0,
                // (b) had serve return due to Hello failure, (c) cleared
                // currentChannel, (d) slept retryInterval, and (e) re-entered
                // runReconnectLoop to ask for the next fd. Signal the test body
                // so it can assert liveChannel is still nil (the fix under test),
                // then wait for the test to give the go-ahead.
                firstFailedGate.signal()
                secondProvideGate.wait()
            }
            if let fd = fdBox.fd(at: n - 1) {
                return .success(fd)
            } else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()

        // Wait (on a background thread) until the provider is entered for the
        // second time, then assert liveChannel is nil before releasing the gate.
        // Must not block the cooperative thread pool — bridge via a detached thread.
        // AtomicInt stores the snapshot: 1 = liveChannel was nil (fix worked), 0 = non-nil (regression).
        let liveChannelWasNilSnapshot = AtomicInt()
        DispatchQueue.global(qos: .userInitiated).async {
            firstFailedGate.wait()
            // By the time the provider is called a second time, serve() for
            // the broken connection has already returned without publishing
            // liveChannel (that is exactly what the fix under test enforces).
            let isNil = DispatchQueue.main.sync {
                agent.liveChannelForTesting == nil
            }
            if isNil { liveChannelWasNilSnapshot.increment() }
            secondProvideGate.signal()
        }

        // The retry should reach the second (healthy) connection and Hello should
        // arrive on host1. liveChannel must only become non-nil for the second
        // connection — never for the first (broken) one.
        let hello = try await nextFrame(from: host1, timeout: .seconds(3))
        guard case .hello = hello.payload else {
            throw TestFailure("Expected Hello on retry connection, got \(String(describing: hello.payload))")
        }
        // Reply with host Hello so liveChannel is published.
        try host1.send(makeHelloFrame())
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Socket provider was called at least twice (once for the failed fd,
        // once for the healthy fd).
        #expect(provideCount.value >= 2)

        // The snapshot taken between first failure and second provide must be nil —
        // this is the load-bearing assertion that the fix prevents premature publish.
        #expect(liveChannelWasNilSnapshot.value == 1, "liveChannel was non-nil during the failed Hello connection: fix did not abort before publish")
    }

    @Test("handleRequest with unsupported format replies with an Error frame")
    func unsupportedFormatRepliesWithError() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        pasteboard.setString("guest content", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .unspecified  // any non-textUtf8 value
        }
        try hostChannel.send(request)

        // Expect an Error frame — not silence.
        let response = try await nextFrame(from: hostChannel)
        guard case .error(let err) = response.payload else {
            throw TestFailure("Expected Error frame, got \(String(describing: response.payload))")
        }
        #expect(err.code == "clipboard.format.unavailable")
        #expect(err.inReplyTo == "clipboard.request")
        #expect(err.message.contains("gen=\(offer.generation)"))
    }

    @Test("handleRequest data-send failure is logged without crashing and leaves state coherent")
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

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        pasteboard.setString("guest data", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        // Queue the request in the kernel buffer, then close the host end so
        // the agent's data-send reply arrives at a dead peer.
        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .textUtf8
        }
        try hostChannel.send(request)
        hostChannel.close()

        // The agent reads the request, tries to send data, fails (peer gone),
        // logs .error, and attempts a best-effort error frame (also fails,
        // swallowed). It must not crash and liveChannel must be cleared once
        // the receive loop observes EOF.
        try await waitUntil(timeout: .seconds(3)) { agent.liveChannelForTesting == nil }
        #expect(agent.liveChannelForTesting == nil, "liveChannel should be nil after peer EOF")
    }

    @Test("full inbound offer/request/data round-trip writes pasteboard")
    func inboundRoundTripWritesPasteboard() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        try hostChannel.send(makeOfferFrame(generation: 42))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        #expect(req.generation == 42)
        #expect(req.format == .textUtf8)

        try hostChannel.send(makeDataFrame(generation: 42, text: "clipboard payload"))

        try await waitUntil { pasteboard.string(forType: .string) == "clipboard payload" }
        #expect(pasteboard.string(forType: .string) == "clipboard payload")
    }

    @Test("setString failure preserves echo-suppression state")
    func setStringFailureDoesNotCorruptEchoSuppression() async throws {
        let pasteboard = FakePasteboard()
        // Start with existing text so clearContents() in handleData is visible
        // and we can confirm handleData actually ran and modified the pasteboard.
        pasteboard.setString("initial guest text", forType: .string)
        #expect(pasteboard.string(forType: .string) == "initial guest text")

        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Inject a single setString failure, then have the host send offer + data.
        pasteboard.failNextSetString()
        try hostChannel.send(makeOfferFrame(generation: 1))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        try hostChannel.send(makeDataFrame(generation: 1, text: "host text that fails to write"))

        // Wait until clearContents() runs (which clears the initial text) and
        // the failed setString() guard returns — confirmed by the pasteboard
        // being empty. This also proves handleData ran and reached the guard.
        try await waitUntil { pasteboard.string(forType: .string) == nil }
        #expect(pasteboard.string(forType: .string) == nil)

        // The regression under test: buggy code stored "host text that fails to write"
        // as lastSeenText even though the write failed. With the fix, lastSeenText
        // remains nil. Copying the same text the host tried to write must still
        // produce an outbound offer (it would be echo-suppressed with the bug).
        pasteboard.setString("host text that fails to write", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer after user copies same text as failed host write — echo-suppression fired incorrectly (regression)")
        }
    }

    @Test("host retry after setString failure succeeds and updates state")
    func setStringFailureRetrySucceeds() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // First attempt: inject failure, send offer + data.
        let countBeforeFirstAttempt = pasteboard.changeCount
        pasteboard.failNextSetString()
        try hostChannel.send(makeOfferFrame(generation: 1))

        let req1 = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest = req1.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: req1.payload))")
        }
        try hostChannel.send(makeDataFrame(generation: 1, text: "retried host text"))

        // Wait until clearContents() runs (changeCount bumps), confirming
        // handleData executed the failed write path before we retry.
        try await waitUntil { pasteboard.changeCount > countBeforeFirstAttempt }

        // pendingInboundGeneration is intentionally left set on failure — the
        // host can re-send the same generation and the agent will accept it.
        // Simulate the host detecting failure and retrying with the same generation.
        try hostChannel.send(makeDataFrame(generation: 1, text: "retried host text"))

        // Wait for the successful write to land.
        try await waitUntil { pasteboard.string(forType: .string) == "retried host text" }
        #expect(pasteboard.string(forType: .string) == "retried host text")

        // Echo suppression must now be set: polling with the same text must not
        // produce an offer (lastSeenText was updated on the successful retry).
        await MainActor.run { agent.checkClipboardChange() }

        let noOfferTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        noOfferTask.cancel()
        let extra = await noOfferTask.value
        if let frame = extra, case .clipboardOffer = frame.payload {
            throw TestFailure("Echo suppression failed after successful retry: agent re-offered host-written text")
        }
    }

    @Test("serve clears liveChannel synchronously before the reconnect loop can proceed")
    func serveSynchronouslyClearsLiveChannelOnClose() async throws {
        let pasteboard = FakePasteboard()

        // Two socket pairs: first for the initial connection that we will close,
        // second for the reconnect that the gating logic intercepts.
        let (agentFd0, remoteFd0) = try makeRawSocketPair()
        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host0 = VsockChannel(fileDescriptor: remoteFd0)
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host0.start()
        host1.start()
        defer { host0.close(); host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        // Gate: signals when the reconnect loop asks for the SECOND fd — i.e.,
        // after the first connection has closed and serve() has returned.
        // Under the new code, serve()'s `await MainActor.run` cleanup completes
        // BEFORE serve returns, so by the time the provider is called a second
        // time, liveChannel is guaranteed to be nil.
        let firstClosedGate = DispatchSemaphore(value: 0)
        // Gate: released by the test body after asserting liveChannel == nil,
        // allowing the reconnect loop to continue with the second fd.
        let secondProvideGate = DispatchSemaphore(value: 0)

        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-sync-cleanup-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            if n == 2 {
                // The reconnect loop has already (a) called serve with fd0,
                // (b) had serve return after the host closed host0,
                // (c) run cleanup to nil out liveChannel via await MainActor.run,
                // (d) cleared currentChannel in VsockGuestClient,
                // (e) slept retryInterval, and (f) re-entered the loop to ask
                // for the next fd. Signal the test so it can assert liveChannel
                // is nil (proving cleanup was synchronous), then wait.
                firstClosedGate.signal()
                secondProvideGate.wait()
            }
            if let fd = fdBox.fd(at: n - 1) {
                return .success(fd)
            } else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()

        // First connection: wait for Hello, reply, wait for liveChannel to be set.
        let hello0 = try await nextFrame(from: host0)
        guard case .hello = hello0.payload else {
            throw TestFailure("Expected Hello on first connection")
        }
        try host0.send(makeHelloFrame())
        try await waitUntil { agent.liveChannelForTesting != nil }
        #expect(agent.liveChannelForTesting != nil)

        // Close the first connection. serve() will observe EOF, run the
        // `await MainActor.run` cleanup block (which clears liveChannel), and
        // return — all before the reconnect loop can advance to the next iteration.
        host0.close()

        // On a background thread, wait for the provider to be called a second
        // time, then snapshot liveChannel via DispatchQueue.main.sync.
        // AtomicInt stores the result: 1 = nil (fix works), 0 = non-nil (regression).
        let liveChannelWasNilAtSecondProvide = AtomicInt()
        DispatchQueue.global(qos: .userInitiated).async {
            firstClosedGate.wait()
            // By the time the provider is called for the second fd, serve() for
            // the first connection has returned. Because serve() runs cleanup via
            // `await MainActor.run` (synchronous from serve's perspective), the
            // main queue has already processed the nil assignment. A regression
            // back to DispatchQueue.main.async would leave a window here where
            // liveChannel could still be non-nil.
            let isNil = DispatchQueue.main.sync {
                agent.liveChannelForTesting == nil
            }
            if isNil { liveChannelWasNilAtSecondProvide.increment() }
            secondProvideGate.signal()
        }

        // The reconnect should reach the second (healthy) connection. Consume
        // the Hello so the test doesn't leave a pending read that would stall.
        let hello1 = try await nextFrame(from: host1, timeout: .seconds(3))
        guard case .hello = hello1.payload else {
            throw TestFailure("Expected Hello on second connection, got \(String(describing: hello1.payload))")
        }

        // The load-bearing assertion: liveChannel was nil at the moment the
        // provider was called for the second fd — proving cleanup ran
        // synchronously before serve returned, not merely eventually.
        #expect(liveChannelWasNilAtSecondProvide.value == 1,
                "liveChannel was non-nil when the reconnect loop asked for the second fd: cleanup was not synchronous")
    }

    @Test("serve publishes liveChannel synchronously so the read loop can process inbound frames immediately")
    func servePublishesLiveChannelBeforeReadLoop() async throws {
        let pasteboard = FakePasteboard()

        // Two socket pairs: first pair establishes the initial connection,
        // second is never used (retries disabled via long retry interval).
        // We use a custom provider so we can intercept between Hello send
        // and the publish MainActor.run.
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // After Hello send, serve() enters `await MainActor.run { liveChannel = channel }`.
        // The main queue must process that block BEFORE serve() enters the read loop.
        // Gating pattern: after the agent sends Hello, we hold the host reply until
        // we've confirmed liveChannel is nil, then release — after which the publish
        // block must have run before any ClipboardOffer can be dispatched.
        //
        // Gate: agent sends Hello → host holds reply → test snapshots liveChannel
        //       (must be nil — publish hasn't run yet) → host sends Hello →
        //       publish MainActor.run runs → liveChannel is non-nil →
        //       host sends Offer → agent processes it (read loop is running).
        //
        // The symmetric claim: after the host Hello is sent and `waitUntil` sees
        // non-nil, any subsequent main-queue work (like a dispatched frame handler)
        // is enqueued AFTER the publish block has already committed.
        let provideCount = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-sync-publish-test",
            retryInterval: .seconds(60)
        ) { _, _ in
            provideCount.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no more fds"))
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }
        agent.start()

        // Wait for Hello from the agent. serve() has sent Hello but has not yet
        // entered the `await MainActor.run` publish block (which is the next step).
        let hello = try await nextFrame(from: hostChannel)
        guard case .hello = hello.payload else {
            throw TestFailure("Expected Hello from agent, got \(String(describing: hello.payload))")
        }

        // Reply with host Hello. This causes serve() to advance to the
        // `await MainActor.run { self.liveChannel = channel }` block and complete
        // it before entering the for-await read loop.
        try hostChannel.send(makeHelloFrame())

        // Wait until publish settles. Under the new code (await MainActor.run),
        // this happens before the read loop starts — so by the time waitUntil
        // returns, the main queue has already committed liveChannel.
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Snapshot on the main queue: liveChannel must be non-nil.
        // A regression back to DispatchQueue.main.async would leave a window where
        // liveChannel is still nil here, because the async dispatch may not have
        // run before the read loop already processed frames.
        let liveChannelSet = DispatchQueue.main.sync { agent.liveChannelForTesting != nil }
        #expect(liveChannelSet,
                "liveChannel was nil on main queue after publish — publish was not synchronous with serve()'s progression")

        // Send an offer and verify the agent processes it, confirming the read
        // loop is running and liveChannel was already set when the frame arrived.
        try hostChannel.send(makeOfferFrame(generation: 1))
        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest in response to offer, got \(String(describing: requestFrame.payload))")
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

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Push the offer into the kernel buffer, then close the host channel.
        // The agent reads the offer; its subsequent attempt to send a request
        // back fails (peer is gone), so handleOffer's catch path runs.
        try hostChannel.send(makeOfferFrame(generation: 42))
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
