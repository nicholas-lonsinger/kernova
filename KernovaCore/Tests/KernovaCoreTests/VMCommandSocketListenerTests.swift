import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaCommandModel
@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaKit

/// The command socket driven end to end over a real `AF_UNIX` socket: a client
/// connects, frames a request, and reads the framed answer back.
///
/// The transport is what is under test; the verbs behind it are a real core
/// over a wired library.
@MainActor
@Suite("VM Command Socket Listener", .caseScoped)
struct VMCommandSocketListenerTests {
    // MARK: - Harness

    private struct Harness {
        let listener: VMCommandSocketListener
        let wired: WiredCommandCore
        let virtualization: MockVirtualizationService
        let authorizer: MockPeerAuthorizer
        /// Fires whenever the listener adopts or forgets a connection.
        let connectionsChanged: AsyncGate
        /// How many times the listener readied the app to surface.
        let preparationCount: Counter
        let path: String
        /// Lets a test hold the library read open, the way a cold launch does.
        let readiness: LibraryReadiness
    }

    /// A tally a production callback writes and the test reads.
    @MainActor
    final class Counter {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    /// The app's first library read, as a gate a test opens when it chooses.
    @MainActor
    final class LibraryReadiness {
        private let gate = AsyncGate()
        private var landed: Bool
        private var waiters = 0

        init(landed: Bool) { self.landed = landed }

        /// Reports the read as complete, releasing everything waiting on it.
        func land() {
            landed = true
            gate.notify()
        }

        /// What the listener awaits before answering a verb.
        func wait() async {
            waiters += 1
            gate.notify()
            try? await gate.wait { self.landed }
        }

        /// Returns once a verb is waiting on the read, throwing at the
        /// backstop if none arrives.
        func verbWaiting() async throws {
            try await gate.wait { self.waiters > 0 }
        }
    }

    /// A group container with a short path: `sockaddr_un.sun_path` holds 104
    /// bytes and the real container's own path already spends most of them in
    /// production.
    private let container = TestScratchDirectory(prefix: "knv")

    /// The claim on a fresh copy of the app, its socket in ``container``.
    private func makeClaim() throws -> AppCopyClaim {
        let bundle = container.url.appendingPathComponent("\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let acquisition = AppCopyClaim.acquire(forAppBundle: bundle, in: container.url)
        let claim: AppCopyClaim? = if case .claimed(let claim) = acquisition { claim } else { nil }
        return try #require(claim, "a fresh copy was not claimed: \(acquisition)")
    }

    private func makeHarness(
        authorization: PeerAuthorization = .authorized,
        libraryHasLanded: Bool = true
    ) throws -> Harness {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let authorizer = MockPeerAuthorizer(authorization)
        let connectionsChanged = AsyncGate()
        let preparationCount = Counter()
        let readiness = LibraryReadiness(landed: libraryHasLanded)
        let claim = try makeClaim()
        let path = claim.socketPath
        let listener = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(commands: wired.core),
            authorizer: authorizer,
            copyClaim: .success(claim),
            awaitReady: { await readiness.wait() },
            prepareToSurface: { preparationCount.increment() })
        listener.onConnectionsChangedForTesting = { connectionsChanged.notify() }
        return Harness(
            listener: listener, wired: wired, virtualization: virtualization, authorizer: authorizer,
            connectionsChanged: connectionsChanged, preparationCount: preparationCount,
            path: path, readiness: readiness)
    }

    // MARK: - Reads

    @Test("A connection is held for its I/O lifetime, and dropped at EOF")
    func connectionCountRisesAndFalls() async throws {
        let harness = try makeHarness()
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        try client.send(VMCommandRequest(verb: .list()))
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
        // The cold-launch shape: the socket is bound, the library is not read
        // yet, and the VMs appear only once it is.
        let harness = try makeHarness(libraryHasLanded: false)
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(VMCommandRequest(verb: .list()))
        try await harness.readiness.verbWaiting()

        // The read lands, and only now does the verb see the library it names:
        // a listing taken before the land would have answered empty.
        harness.wired.register(name: "Alpha")
        let library = harness.wired.core.list(.all)
        harness.readiness.land()

        #expect(library.map(\.name) == ["Alpha"])
        #expect(try await client.nextResponse()?.result == .summaries(library))
    }

    @Test("A permission panel a verb puts up asks the client on that connection to activate")
    func permissionPanelAsksTheConnectionsClient() async throws {
        let harness = try makeHarness()
        // An authority that asks for activation as it puts its panel up, as
        // `PowerboxSourceAuthority` does, and is then dismissed, so the verb
        // answers with the refusal.
        let authority = harness.wired.authority
        authority.whilePanelStands = { ActivationRequester.requestActivation() }
        authority.error = CommandError.operationFailed(verb: .importVM, message: "Not given permission.")
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(
            VMCommandRequest(verb: .importVM(path: "/Users/somebody/Desktop/Alpha.kernova", waitForOutcome: false)))

        #expect(try await client.nextResponse()?.result == .activate)
        #expect(try await client.nextResponse()?.failure != nil)
        #expect(harness.preparationCount.value == 1)
    }

    // MARK: - Envelope refusals

    @Test(
        "A refused peer is told which refusal it is, then disconnected",
        arguments: [
            (
                refusal: PeerRefusal.unidentified,
                sentence: "The connecting process could not be identified."
            ),
            (
                refusal: PeerRefusal.notValidlySigned,
                sentence: "The connecting process is not validly signed."
            ),
            (
                refusal: PeerRefusal.differentTeam,
                sentence: "Only Kernova components signed by the same team may drive this app."
            ),
        ]
    )
    func refusedPeerIsToldWhichRefusal(_ c: (refusal: PeerRefusal, sentence: String)) async throws {
        let harness = try makeHarness(authorization: .refused(c.refusal))
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        let response = try await client.nextResponse()
        // A team mismatch is one of three refusals, and the other two are not
        // worded as one: the sentence says what the check established.
        #expect(response?.result == .refused(.authorizationRefused(reason: c.sentence)))
        // The refusal ends the connection, so the next read is end-of-stream.
        #expect(try await client.nextResponse() == nil)
        // No connection was ever adopted.
        #expect(harness.listener.connectionCountForTesting == 0)
    }

    // MARK: - Subscription

    @Test("A subscription answers with the library, then with each change")
    func subscriptionDeliversSnapshotThenEvents() async throws {
        let harness = try makeHarness()
        let alpha = harness.wired.register(name: "Alpha")
        let library = harness.wired.core.list(.all)
        harness.listener.start()
        defer { harness.listener.stop() }

        let client = try TestCommandClient(connectingTo: harness.path)
        defer { client.close() }

        try client.send(VMCommandRequest(verb: .events))
        #expect(try await client.nextResponse()?.result == .summaries(library))

        try harness.wired.core.rename(.id(alpha.id), to: "Beta")

        #expect(
            try await client.nextResponse()?.result
                == .event(.renamed(id: alpha.id, from: "Alpha", to: "Beta")))
    }
}

/// A client on the command socket, for driving the transport from a test.
///
/// The socket is blocking with a receive deadline, so `nextResponse()` returns
/// the moment bytes land rather than polling for them, and a stuck transport
/// fails the read instead of hanging the suite.
@MainActor
private final class TestCommandClient {
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
