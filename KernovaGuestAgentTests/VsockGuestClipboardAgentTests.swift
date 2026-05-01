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

    var changeCount: Int {
        lock.withLock { _changeCount }
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        lock.withLock { _contents[type] }
    }

    @discardableResult
    func clearContents() -> Int {
        lock.withLock {
            _contents.removeAll()
            _changeCount += 1
            return _changeCount
        }
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        lock.withLock {
            _contents[type] = string
            _changeCount += 1
            return true
        }
    }
}

// MARK: - Test Suite

@Suite("VsockGuestClipboardAgent state machine")
struct VsockGuestClipboardAgentTests {

    private struct TestFailure: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    /// Creates a connected socketpair; returns (agent-side fd, host-side channel).
    private func makeSocketPair() throws -> (agentFd: Int32, hostChannel: VsockChannel) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let host = VsockChannel(fileDescriptor: fds[1])
        host.start()
        return (fds[0], host)
    }

    /// Waits until the predicate is true or a deadline elapses.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !predicate() {
            throw TestFailure("Predicate did not become true within \(timeout)")
        }
    }

    /// Drains the next frame from a channel within a generous deadline.
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

    private func makeHelloFrame() -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["clipboard.text.utf8"]
        }
        return frame
    }

    private func makeOfferFrame(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.formats = [.textUtf8]
        }
        return frame
    }

    private func makeDataFrame(generation: UInt64, text: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = generation
            $0.format = .textUtf8
            $0.data = Data(text.utf8)
        }
        return frame
    }

    private func makeRequestFrame(generation: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = generation
            $0.format = .textUtf8
        }
        return frame
    }

    // MARK: - Helpers for agent setup

    /// Sets up an agent with the given pasteboard and a socket provider that
    /// returns the given fd on first call, nil thereafter. Does NOT retry
    /// (long retry interval) so tests don't interfere.
    private func makeAgent(pasteboard: FakePasteboard, agentFd: Int32) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-test",
            retryInterval: .seconds(60)
        ) { _, _ in
            let n = provided.increment()
            return n == 1 ? agentFd : nil
        }
        return VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
    }

    /// Starts the agent and waits until the host side receives the Hello frame.
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
    }

    // MARK: - Tests

    @Test("outbound offer is sent when local pasteboard changes")
    func outboundOfferOnPasteboardChange() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, hostChannel) = try makeSocketPair()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Change pasteboard then trigger a poll synchronously on main queue
        pasteboard.setString("hello from guest", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        // Expect a ClipboardOffer from the agent
        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            Issue.record("Expected ClipboardOffer, got \(String(describing: frame.payload))")
            return
        }
        #expect(offer.formats.contains(.textUtf8))
        #expect(offer.generation >= 1)
    }

    @Test("echo suppression — text just written from host is not re-offered")
    func echoSuppression() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, hostChannel) = try makeSocketPair()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Host sends offer → agent requests → host sends data → agent writes pasteboard
        try hostChannel.send(makeOfferFrame(generation: 1))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            Issue.record("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
            return
        }
        #expect(req.generation == 1)

        try hostChannel.send(makeDataFrame(generation: 1, text: "from host"))

        try await waitUntil {
            pasteboard.string(forType: .string) == "from host"
        }
        #expect(pasteboard.string(forType: .string) == "from host")

        // Poll — since we just received "from host", no re-offer should be sent
        await MainActor.run { agent.checkClipboardChange() }

        // Give a short window; no offer should arrive
        try await Task.sleep(for: .milliseconds(150))
        // Drain any buffered frames from the host channel
        let extraTask = Task<Frame?, Never> {
            var iterator = hostChannel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(100))
        extraTask.cancel()
        let extra = await extraTask.value
        if let frame = extra {
            if case .clipboardOffer = frame.payload {
                Issue.record("Echo suppression failed: agent re-offered host-written text")
            }
        }
    }

    @Test("reconnect resets lastSeenText so agent re-offers current pasteboard")
    func reconnectResetsLastSeenText() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setString("persistent text", forType: .string)

        // Prepare two socketpairs
        var agentFds: [Int32] = []
        var hostChannels: [VsockChannel] = []
        for _ in 0..<2 {
            var fds: [Int32] = [-1, -1]
            let rc = fds.withUnsafeMutableBufferPointer { buf in
                socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
            }
            guard rc == 0 else { throw POSIXError(.EIO) }
            agentFds.append(fds[0])
            let host = VsockChannel(fileDescriptor: fds[1])
            host.start()
            hostChannels.append(host)
        }
        defer { hostChannels.forEach { $0.close() } }

        // Use AtomicInt for the provide counter to avoid Swift 6 capture errors
        let provideCount = AtomicInt()
        // Store fds in a thread-safe box
        let fdBox = FdBox(fds: agentFds)

        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-reconnect-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            return fdBox.fd(at: n - 1)
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()

        // First connection: consume Hello
        let hello1 = try await nextFrame(from: hostChannels[0])
        guard case .hello = hello1.payload else {
            throw TestFailure("Expected Hello on first connection")
        }

        // Trigger a poll — agent should offer "persistent text"
        await MainActor.run { agent.checkClipboardChange() }

        let offer1Frame = try await nextFrame(from: hostChannels[0])
        guard case .clipboardOffer(let offer1) = offer1Frame.payload else {
            Issue.record("Expected ClipboardOffer on first connection")
            return
        }
        #expect(offer1.generation >= 1)

        // Close first connection to force reconnect
        hostChannels[0].close()

        // Wait for second connection Hello
        let hello2 = try await nextFrame(from: hostChannels[1], timeout: .seconds(3))
        guard case .hello = hello2.payload else {
            throw TestFailure("Expected Hello on second connection")
        }

        // After reconnect, lastSeenText is cleared — next poll should re-offer
        await MainActor.run { agent.checkClipboardChange() }

        let offer2Frame = try await nextFrame(from: hostChannels[1])
        guard case .clipboardOffer(let offer2) = offer2Frame.payload else {
            Issue.record("Expected ClipboardOffer after reconnect")
            return
        }
        #expect(offer2.generation > offer1.generation)
    }

    @Test("stale ClipboardData with wrong generation is dropped")
    func staleClipboardDataDropped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, hostChannel) = try makeSocketPair()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        // Host sends an offer with generation 5
        try hostChannel.send(makeOfferFrame(generation: 5))
        _ = try await nextFrame(from: hostChannel)  // Consume agent's request

        // Send data with wrong generation (4 instead of 5)
        try hostChannel.send(makeDataFrame(generation: 4, text: "stale data"))

        // Wait briefly — pasteboard should NOT be written
        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("full inbound offer/request/data round-trip writes pasteboard")
    func inboundRoundTripWritesPasteboard() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, hostChannel) = try makeSocketPair()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForHello(agent: agent, hostChannel: hostChannel)

        try hostChannel.send(makeOfferFrame(generation: 42))

        let requestFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardRequest(let req) = requestFrame.payload else {
            Issue.record("Expected ClipboardRequest, got \(String(describing: requestFrame.payload))")
            return
        }
        #expect(req.generation == 42)
        #expect(req.format == .textUtf8)

        try hostChannel.send(makeDataFrame(generation: 42, text: "clipboard payload"))

        try await waitUntil {
            pasteboard.string(forType: .string) == "clipboard payload"
        }
        #expect(pasteboard.string(forType: .string) == "clipboard payload")
    }
}

// MARK: - Thread-safe fd array

/// Sendable wrapper for an array of file descriptors used in socket provider closures.
private final class FdBox: @unchecked Sendable {
    private let lock = NSLock()
    private let fds: [Int32]

    init(fds: [Int32]) {
        self.fds = fds
    }

    func fd(at index: Int) -> Int32? {
        lock.withLock {
            guard index >= 0 && index < fds.count else { return nil }
            return fds[index]
        }
    }
}
