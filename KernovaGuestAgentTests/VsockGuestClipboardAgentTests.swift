import Testing
import Foundation
import AppKit
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
    private func makeAgent(pasteboard: FakePasteboard, agentFd: Int32) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
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

        try await startAgentAndWaitForLiveChannel(agent: agent)

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

        try await startAgentAndWaitForLiveChannel(agent: agent)

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

    @Test("stale ClipboardData with wrong generation is dropped")
    func staleClipboardDataDropped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeOfferFrame(generation: 5))
        _ = try await nextFrame(from: hostChannel)  // Consume agent's request

        // Send data with wrong generation (4 instead of 5)
        try hostChannel.send(makeDataFrame(generation: 4, text: "stale data"))

        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == nil)
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

        try await startAgentAndWaitForLiveChannel(agent: agent)

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

        try await startAgentAndWaitForLiveChannel(agent: agent)

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
        try await waitUntil(timeout: .seconds(2)) { agent.liveChannelForTesting == nil }
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

        try await startAgentAndWaitForLiveChannel(agent: agent)

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

    @Test("pasteboard write failure preserves echo-suppression state")
    func writeFailureDoesNotCorruptEchoSuppression() async throws {
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

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Inject a single setString failure, then have the host send offer + data.
        pasteboard.failNextWrite()
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
        // in the echo-suppression digest even though the write failed. With the fix, the digest
        // remains nil. Copying the same text the host tried to write must still
        // produce an outbound offer (it would be echo-suppressed with the bug).
        pasteboard.setString("host text that fails to write", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer = offerFrame.payload else {
            throw TestFailure(
                "Expected ClipboardOffer after user copies same text as failed host write — echo-suppression fired incorrectly (regression)"
            )
        }
    }

    @Test("host retry after pasteboard write failure succeeds and updates state")
    func writeFailureRetrySucceeds() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // First attempt: inject failure, send offer + data.
        let countBeforeFirstAttempt = pasteboard.changeCount
        pasteboard.failNextWrite()
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
        // produce an offer (lastSeenDigest was updated on the successful retry).
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

    // RATIONALE: The "serve clears liveChannel synchronously before the
    // reconnect loop can proceed" test was deleted in the refactor that moved
    // the version handshake to the always-on control channel
    // (`VsockGuestControlAgent`). The cleanup invariant it tested is
    // preserved in `serve()`'s `await MainActor.run` block, but the original
    // gating relied on the Hello round-trip's natural delay to keep
    // host-side and agent-side serve()/read-loop progress synchronized;
    // without that delay the gates race in a way that's not worth
    // engineering around for a property already covered by
    // `servePublishesLiveChannelBeforeReadLoop` on the publish side.

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
        try hostChannel.send(makeOfferFrame(generation: 1))
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

    // MARK: - UTI representations

    @Test("snapshot offers UTIs in pasteboard order plus the legacy text format")
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
        #expect(offer.utis == ["public.rtf", NSPasteboard.PasteboardType.string.rawValue])
        #expect(offer.formats == [.textUtf8])
    }

    @Test("transient markers and file references are filtered; all-filtered pasteboard sends no offer")
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
            (type: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), data: Data([1])),
            (type: NSPasteboard.PasteboardType("public.file-url"), data: Data("file:///x".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        let extra = await extraTask.value
        if let frame = extra, case .clipboardOffer = frame.payload {
            throw TestFailure("Agent offered a snapshot whose every representation should be filtered")
        }
    }

    @Test("filtered marker alongside real content offers only the real representations")
    func mixedFilteredTypesOfferRealContentOnly() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.writeItem(representations: [
            (type: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), data: Data([1])),
            (type: .string, data: Data("secret".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(offer.utis == [NSPasteboard.PasteboardType.string.rawValue])
    }

    @Test("inbound representations land as one pasteboard item and are echo-suppressed")
    func inboundRepresentationsRoundTrip() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(generation: 9, utis: ["public.png", NSPasteboard.PasteboardType.string.rawValue]))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            throw TestFailure("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
        }
        // A UTI-capable offer must be answered with a UTI request.
        #expect(req.generation == 9)
        #expect(req.utis == ["public.png", NSPasteboard.PasteboardType.string.rawValue])

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        try hostChannel.send(
            makeDataFrame(
                generation: 9,
                representations: [
                    (uti: "public.png", data: pngBytes),
                    (uti: NSPasteboard.PasteboardType.string.rawValue, data: Data("caption".utf8)),
                ]))

        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == pngBytes
        }
        #expect(
            pasteboard.firstItemTypes.map(\.rawValue) == [
                "public.png", NSPasteboard.PasteboardType.string.rawValue,
            ])
        #expect(pasteboard.string(forType: .string) == "caption")

        // Echo suppression: the write bumped changeCount, but the agent
        // recorded it — a poll must not re-offer the host's own content.
        await MainActor.run { agent.checkClipboardChange() }
        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        let extra = await extraTask.value
        if let frame = extra, case .clipboardOffer = frame.payload {
            throw TestFailure("Echo suppression failed: agent re-offered host-written representations")
        }
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

        try hostChannel.send(makeOfferFrame(generation: 11, utis: ["public.png", "public.file-url"]))
        _ = try await nextFrame(from: hostChannel)  // request

        let pngBytes = Data([0x89, 0x50])
        try hostChannel.send(
            makeDataFrame(
                generation: 11,
                representations: [
                    (uti: "public.file-url", data: Data("file:///etc/hosts".utf8)),
                    (uti: "public.png", data: pngBytes),
                ]))

        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) == pngBytes
        }
        #expect(pasteboard.firstItemTypes.map(\.rawValue) == ["public.png"])
    }

    @Test("UTI request returns the requested representations from the pending offer")
    func utiRequestServesRepresentations() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        pasteboard.writeItem(representations: [
            (type: NSPasteboard.PasteboardType("public.png"), data: pngBytes),
            (type: .string, data: Data("alt text".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.utis = ["public.png"]
        }
        try hostChannel.send(request)

        let dataFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardData(let data) = dataFrame.payload else {
            throw TestFailure("Expected ClipboardData, got \(String(describing: dataFrame.payload))")
        }
        #expect(data.generation == offer.generation)
        #expect(data.representations.map(\.uti) == ["public.png"])
        #expect(data.representations.first?.data == pngBytes)
        #expect(data.data.isEmpty)
    }

    @Test("oversized representation is dropped from the offer while its text sibling survives")
    func oversizedRepresentationDropped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.writeItem(representations: [
            (
                type: NSPasteboard.PasteboardType("public.tiff"),
                data: Data(count: ClipboardSnapshotPolicy.maxRepresentationByteCount + 1)
            ),
            (type: .string, data: Data("small".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(offer.utis == [NSPasteboard.PasteboardType.string.rawValue])
    }

    // MARK: - Copied files

    @Test("a copied image file is expanded to the image itself")
    func copiedImageFileExpandsToImage() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Exactly what Finder ⌘C on an image file produces: a file URL plus
        // the name, no pixels.
        let png = try makeTestPNG()
        let url = try writeTempFile(name: "picture.png", data: png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.writeItem(representations: [
            (type: .fileURL, data: Data(url.absoluteString.utf8)),
            (type: .string, data: Data("picture".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        // The image won — not the filename text.
        #expect(offer.utis == [UTType.png.identifier])
        #expect(offer.formats.isEmpty)

        // And the bytes that cross are the file's bytes.
        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.utis = [UTType.png.identifier]
        }
        try hostChannel.send(request)
        let dataFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardData(let data) = dataFrame.payload else {
            throw TestFailure("Expected ClipboardData, got \(String(describing: dataFrame.payload))")
        }
        #expect(data.representations.first?.data == png)
        // The filename rides along so the host can paste it as a file.
        #expect(data.representations.first?.filename == "picture.png")
    }

    @Test("an inbound file representation is staged and a file URL is written alongside the image")
    func inboundFileStagesAndWritesFileURL() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        try hostChannel.send(makeOfferFrame(generation: 5, utis: [UTType.png.identifier]))
        _ = try await nextFrame(from: hostChannel)  // request

        var data = Frame()
        data.protocolVersion = 1
        data.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = 5
            $0.representations = [
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = UTType.png.identifier
                    $0.data = png
                    $0.filename = "shot.png"
                }
            ]
        }
        try hostChannel.send(data)

        // The inline image AND a staged file URL land on the pasteboard.
        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)) == png
        }
        #expect(pasteboard.firstItemTypes.contains(.fileURL))
        let staged = try #require(pasteboard.writtenFileURLs.first)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(staged.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: staged) == png)

        // Echo suppression holds even with the .fileURL on the pasteboard: the
        // poll re-expands the staged file to the same digest and does not
        // re-offer it.
        await MainActor.run { agent.checkClipboardChange() }
        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        if let frame = await extraTask.value, case .clipboardOffer = frame.payload {
            throw TestFailure("Echo suppression failed: re-offered the staged file it just received")
        }
    }

    @Test("an inbound representation without a filename writes inline only (old-agent interop)")
    func inboundWithoutFilenameNoStaging() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        try hostChannel.send(makeOfferFrame(generation: 7, utis: [UTType.png.identifier]))
        _ = try await nextFrame(from: hostChannel)  // request
        // No filename — as an old agent (pre-filename field) would send.
        try hostChannel.send(
            makeDataFrame(generation: 7, representations: [(uti: UTType.png.identifier, data: png)]))

        try await waitUntil {
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)) == png
        }
        #expect(!pasteboard.firstItemTypes.contains(.fileURL))
        #expect(pasteboard.writtenFileURLs.isEmpty)
    }

    @Test("an inbound non-image file is written as a file URL only, not inlined")
    func inboundNonImageFileWritesFileURLOnly() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let contents = Data("file contents".utf8)
        try hostChannel.send(makeOfferFrame(generation: 8, utis: [txtUTI]))
        _ = try await nextFrame(from: hostChannel)  // request

        var data = Frame()
        data.protocolVersion = 1
        data.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = 8
            $0.representations = [
                Kernova_V1_ClipboardRepresentation.with {
                    $0.uti = txtUTI
                    $0.data = contents
                    $0.filename = "notes.txt"
                }
            ]
        }
        try hostChannel.send(data)

        // The file URL lands; the contents are NOT inlined under the text UTI,
        // so the receiver attaches the file rather than inserting its text.
        try await waitUntil { pasteboard.firstItemTypes.contains(.fileURL) }
        #expect(!pasteboard.firstItemTypes.contains(NSPasteboard.PasteboardType(txtUTI)))
        let staged = try #require(pasteboard.writtenFileURLs.first)
        #expect(staged.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: staged) == contents)
    }

    @Test("a copied non-image file crosses as the file itself (bytes + name)")
    func copiedNonImageFileExpandsToFile() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let contents = Data("contents".utf8)
        let url = try writeTempFile(name: "notes.txt", data: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A copied text file: the OS leaves the file URL and the name as plain
        // text. The agent reads the file so its bytes cross tagged with the
        // file's content UTI and name (the host materializes a real file).
        pasteboard.writeItem(representations: [
            (type: .fileURL, data: Data(url.absoluteString.utf8)),
            (type: .string, data: Data("notes.txt".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        // The file crossed, not the name-as-text: a single file rep, no legacy
        // text format (its UTI is public.plain-text, not utf8-plain-text).
        #expect(offer.utis == [txtUTI])
        #expect(offer.formats.isEmpty)

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.utis = [txtUTI]
        }
        try hostChannel.send(request)
        let dataFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardData(let data) = dataFrame.payload else {
            throw TestFailure("Expected ClipboardData, got \(String(describing: dataFrame.payload))")
        }
        #expect(data.representations.first?.data == contents)
        #expect(data.representations.first?.filename == "notes.txt")
    }

    @Test("a copied file over the per-representation cap produces no offer")
    func copiedOverCapFileProducesNoOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A copied file just over the per-rep cap: fileExpansionCandidate logs
        // and returns nil, and the snapshot then filters the file URL — so
        // nothing crosses (the over-cap bytes never become an offer).
        let url = try writeTempFile(
            name: "huge.bin",
            data: Data(count: ClipboardSnapshotPolicy.maxRepresentationByteCount + 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.writeItem(representations: [
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        if let frame = await extraTask.value, case .clipboardOffer = frame.payload {
            throw TestFailure("Agent offered an over-cap copied file that should have been skipped")
        }
    }

    @Test("overlapping polls during an in-flight file expansion produce exactly one offer")
    func concurrentPollsDuringFileExpansionOfferOnce() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let url = try writeTempFile(name: "doc.bin", data: Data(count: 64 * 1024))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.writeItem(representations: [
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        // Two rapid polls: the first starts an off-main read and sets the
        // in-flight flag; the second must no-op rather than start a second read
        // and emit a duplicate offer for the same change.
        await MainActor.run {
            agent.checkClipboardChange()
            agent.checkClipboardChange()
        }

        // The in-flight guard's real effect is skipping the second large-file
        // READ — assert that directly. A duplicate *offer* alone wouldn't isolate
        // the guard, since digest echo-suppression independently collapses it.
        let expansionsStarted = await MainActor.run { agent.fileExpansionsStartedForTesting }
        #expect(expansionsStarted == 1)

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        // No second offer should arrive for the same in-flight expansion.
        let extraTask = Task<Frame?, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(200))
        extraTask.cancel()
        if let frame = await extraTask.value, case .clipboardOffer = frame.payload {
            throw TestFailure("Re-entrant poll produced a duplicate offer for the in-flight file expansion")
        }
    }

    // MARK: - Image-file test helpers

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
