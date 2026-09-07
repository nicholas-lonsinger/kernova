import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The command socket driven end to end over a real `AF_UNIX` socket: a client
/// connects, frames a request, and reads the framed answer back.
///
/// The transport is what is under test — the verbs behind it are
/// `MockVMCommanding`, which the router tests already drive against the real
/// core.
@MainActor
@Suite("VM Command Socket Listener", .admissionGated)
struct VMCommandSocketListenerTests {
    // MARK: - Harness

    private struct Harness {
        let listener: VMCommandSocketListener
        let commands: MockVMCommanding
        let authorizer: MockPeerAuthorizer
        /// Fires whenever the listener adopts or forgets a connection.
        let connectionsChanged: AsyncGate
        /// Fires when the listener asks the app to come forward.
        let surfaced: AsyncGate
        let surfaceCount: Counter
        let path: String
        /// Lets a test hold the library read open, the way a cold launch does.
        let readiness: LibraryReadiness
    }

    /// A tally a production callback writes and the test reads.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func increment() { lock.withLock { count += 1 } }
    }

    /// The app's first library read, as a gate a test opens when it chooses.
    ///
    /// Lock-guarded rather than `@MainActor`: production awaits it while the
    /// test holds the main actor.
    final class LibraryReadiness: @unchecked Sendable {
        private let gate = AsyncGate()
        private let lock = NSLock()
        private var landed: Bool

        init(landed: Bool) { self.landed = landed }

        /// Reports the read as complete, releasing everything waiting on it.
        func land() {
            lock.withLock { landed = true }
            gate.notify()
        }

        /// What the listener awaits before answering a verb.
        func wait() async {
            try? await gate.wait { self.lock.withLock { self.landed } }
        }
    }

    /// A short path: `sockaddr_un.sun_path` holds 104 bytes and the container's
    /// own path already spends most of them in production.
    private func temporarySocketPath() -> String {
        let short = UUID().uuidString.prefix(8).lowercased()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("knv-c-\(short).sock")
    }

    private func makeHarness(
        authorized: Bool = true,
        library: [VMSummary] = [],
        libraryHasLanded: Bool = true
    ) -> Harness {
        let commands = MockVMCommanding()
        commands.library = library
        let authorizer = MockPeerAuthorizer(isAuthorizedResult: authorized)
        let connectionsChanged = AsyncGate()
        let surfaced = AsyncGate()
        let surfaceCount = Counter()
        let readiness = LibraryReadiness(landed: libraryHasLanded)
        let path = temporarySocketPath()
        let listener = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(
                commands: commands, importAuthority: MockImportSourceAuthority()),
            authorizer: authorizer,
            socketPath: path,
            awaitReady: { await readiness.wait() },
            onSurfaceRequested: {
                surfaceCount.increment()
                surfaced.notify()
            })
        listener.onConnectionsChangedForTesting = { connectionsChanged.notify() }
        return Harness(
            listener: listener, commands: commands, authorizer: authorizer,
            connectionsChanged: connectionsChanged, surfaced: surfaced, surfaceCount: surfaceCount,
            path: path, readiness: readiness)
    }

    // MARK: - Reads

    @Test("A read verb round-trips over the socket")
    func unaryReadRoundTrips() async throws {
        let alpha = VMSummary(id: UUID(), name: "Alpha", status: "stopped", ipAddress: .unavailable)
        let harness = makeHarness(library: [alpha])
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(VMCommandRequest(verb: .list))
        let response = try await client.nextResponse()

        #expect(response?.result == .summaries([alpha]))
        #expect(harness.authorizer.checkCount == 1)
    }

    @Test("A connection is held for its I/O lifetime, and dropped at EOF")
    func connectionCountRisesAndFalls() async throws {
        let harness = makeHarness()
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        try client.send(VMCommandRequest(verb: .list))
        // The answer proves the connection was adopted on the main actor: the
        // count is written in the same hop that starts reading.
        _ = try await client.nextResponse()
        #expect(harness.listener.connectionCountForTesting == 1)

        client.close()
        try await harness.connectionsChanged.wait {
            harness.listener.connectionCountForTesting == 0
        }
        #expect(harness.listener.connectionCountForTesting == 0)
    }

    @Test("No verb is answered until the app's first library read has landed")
    func verbsWaitForTheLibraryRead() async throws {
        let alpha = VMSummary(id: UUID(), name: "Alpha", status: "stopped", ipAddress: .unavailable)
        // The cold-launch shape: the socket is bound, the library is not read
        // yet, and the VMs appear only once it is.
        let harness = makeHarness(library: [], libraryHasLanded: false)
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(VMCommandRequest(verb: .list))

        // RATIONALE: a fixed observation window, the negative-assertion case
        // docs/TESTING.md sanctions — the claim is that nothing arrives, and
        // there is no signal for an event that must not happen. An empty
        // library reported as the truth is worse than any refusal, because it
        // exits 0.
        client.observe(forAtMost: 2)
        #expect(try await client.nextResponse() == nil)
        #expect(harness.commands.listCallCount == 0)

        // The read lands, and only now does the verb see the library it names.
        client.observeWithBackstop()
        harness.commands.library = [alpha]
        harness.readiness.land()

        #expect(try await client.nextResponse()?.result == .summaries([alpha]))
    }

    @Test("A verb that surfaces asks the app forward first; one that does not, does not")
    func surfacingVerbsAskTheAppForward() async throws {
        let alpha = VMSummary(id: UUID(), name: "Alpha", status: "running", ipAddress: .unavailable)
        let harness = makeHarness(library: [alpha])
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        // A read puts nothing on screen, so nothing is brought forward.
        try client.send(VMCommandRequest(verb: .list))
        _ = try await client.nextResponse()
        #expect(harness.surfaceCount.value == 0)

        // `open` does, and a window ordered front behind the terminal that
        // asked for it has answered nobody.
        try client.send(VMCommandRequest(verb: .open(.id(alpha.id))))
        _ = try await client.nextResponse()
        try await harness.surfaced.wait { harness.surfaceCount.value == 1 }
        #expect(harness.surfaceCount.value == 1)

        // A headless start is a bring-up nobody asked to see.
        try client.send(
            VMCommandRequest(
                verb: .start(.id(alpha.id), recovery: false, presentation: .headless)))
        _ = try await client.nextResponse()
        #expect(harness.surfaceCount.value == 1)
    }

    // MARK: - Envelope refusals

    @Test("An unauthorized peer is told so, then disconnected")
    func unauthorizedPeerIsRefusedAndClosed() async throws {
        let harness = makeHarness(authorized: false)
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        let response = try await client.nextResponse()
        guard case .refused(.authorizationRefused) = response?.result else {
            Issue.record("expected an authorization refusal, got \(String(describing: response))")
            return
        }
        // The refusal ends the connection, so the next read is end-of-stream.
        #expect(try await client.nextResponse() == nil)
        // Nothing reached the verbs, and no connection was ever adopted.
        #expect(harness.commands.library.isEmpty)
        #expect(harness.listener.connectionCountForTesting == 0)
    }

    @Test("A peer speaking another protocol version is refused before any verb runs")
    func foreignProtocolVersionIsRefused() async throws {
        let alpha = VMSummary(id: UUID(), name: "Alpha", status: "stopped", ipAddress: .unavailable)
        let harness = makeHarness(library: [alpha])
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        var request = VMCommandRequest(verb: .list)
        request.protocolVersion = VMCommandRequest.currentProtocolVersion + 1
        try client.send(request)

        let response = try await client.nextResponse()
        #expect(
            response?.result
                == .refused(
                    .unsupportedProtocolVersion(
                        peer: VMCommandRequest.currentProtocolVersion + 1,
                        expected: VMCommandRequest.currentProtocolVersion)))
        #expect(harness.commands.listCallCount == 0)
    }

    @Test("Bytes that are not a request are refused, and end the connection")
    func undecodableBytesAreRefused() async throws {
        let harness = makeHarness()
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.sendRaw(Data("not a request".utf8))

        let response = try await client.nextResponse()
        guard case .refused(.undecodableRequest) = response?.result else {
            Issue.record("expected an undecodable-request refusal, got \(String(describing: response))")
            return
        }
        #expect(try await client.nextResponse() == nil)
    }

    // MARK: - Subscription

    @Test("A subscription answers with the library, then with each change")
    func subscriptionDeliversSnapshotThenEvents() async throws {
        let alpha = VMSummary(id: UUID(), name: "Alpha", status: "stopped", ipAddress: .unavailable)
        let harness = makeHarness(library: [alpha])
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(VMCommandRequest(verb: .events))
        #expect(try await client.nextResponse()?.result == .summaries([alpha]))

        let change = VMLibraryEvent.statusChanged(
            id: alpha.id, name: "Alpha", from: "stopped", to: "running")
        harness.commands.emit(change)

        #expect(try await client.nextResponse()?.result == .event(change))
    }

    // MARK: - Degraded builds

    @Test("A build with no group container publishes no socket")
    func noContainerBindsNothing() {
        let listener = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(
                commands: MockVMCommanding(), importAuthority: MockImportSourceAuthority()),
            authorizer: MockPeerAuthorizer(),
            socketPath: nil,
            awaitReady: {},
            onSurfaceRequested: {})
        listener.start()
        #expect(listener.connectionCountForTesting == 0)
        listener.stop()
    }

    @Test("A build whose signature names no team publishes no socket")
    func noAuthorizerBindsNothing() {
        let path = temporarySocketPath()
        let listener = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(
                commands: MockVMCommanding(), importAuthority: MockImportSourceAuthority()),
            authorizer: nil,
            socketPath: path,
            awaitReady: {},
            onSurfaceRequested: {})
        listener.start()
        #expect(!FileManager.default.fileExists(atPath: path))
        listener.stop()
    }
}

/// A client on the command socket, for driving the transport from a test.
///
/// The socket is blocking with a receive deadline, so `nextResponse()` returns
/// the moment bytes land rather than polling for them, and a stuck transport
/// fails the read instead of hanging the suite.
private final class TestCommandClient: @unchecked Sendable {
    private let fd: Int32
    private var decoder = StreamFrameDecoder()
    private var isClosed = false

    init(connectingTo path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure("client socket() failed: errno \(errno)") }

        var address = try UnixSocketAddress.make(path: path)
        let connected = UnixSocketAddress.withSockaddr(&address) { socketAddress, length in
            connect(descriptor, socketAddress, length)
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw TestFailure("client connect() failed: errno \(errno)")
        }

        var deadline = timeval(tv_sec: Int(testWaitBackstop), tv_usec: 0)
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline,
            socklen_t(MemoryLayout<timeval>.size))
        fd = descriptor
    }

    func send(_ request: VMCommandRequest) throws {
        try sendRaw(try JSONEncoder().encode(request))
    }

    func sendRaw(_ payload: Data) throws {
        let framed = try StreamFrame.encode(payload)
        var offset = 0
        try framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw TestFailure("client write() failed: errno \(errno)")
                }
                offset += written
            }
        }
    }

    /// Narrows the read deadline to `seconds`, for a negative assertion that
    /// has to bound how long it watches.
    func observe(forAtMost seconds: Int) {
        var deadline = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Restores the full backstop deadline.
    func observeWithBackstop() {
        observe(forAtMost: Int(testWaitBackstop))
    }

    /// The next framed response, or `nil` at end of stream.
    func nextResponse() async throws -> VMCommandResponse? {
        while true {
            if let payload = try decoder.nextFrame() {
                return try JSONDecoder().decode(VMCommandResponse.self, from: Data(payload))
            }
            let descriptor = fd
            let chunk = await offCooperativePool { () -> Data? in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                guard count > 0 else { return nil }
                return Data(buffer[0..<count])
            }
            guard let chunk else { return nil }  // EOF, error, or the deadline
            decoder.feed(chunk)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}
