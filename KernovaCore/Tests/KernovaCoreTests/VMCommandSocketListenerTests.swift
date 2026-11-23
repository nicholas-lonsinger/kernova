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
        let path: String
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

    private func makeHarness(authorization: PeerAuthorization) throws -> Harness {
        let wired = WiredCommandCore(virtualization: MockVirtualizationService())
        let claim = try makeClaim()
        let listener = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(commands: wired.core),
            authorizer: MockPeerAuthorizer(authorization),
            copyClaim: .success(claim),
            awaitReady: {},
            prepareToSurface: {})
        return Harness(listener: listener, path: claim.socketPath)
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
        defer { harness.listener.stopForTesting() }

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
}

/// A client on the command socket, for driving the transport from a test.
///
/// The socket is blocking, so `nextResponse()` returns the moment bytes land
/// rather than polling for them; a stuck transport fails the read's wait at
/// its backstop, and `close()` ends the read it abandoned.
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

        fd = descriptor
    }

    /// The next framed response, or `nil` at end of stream.
    func nextResponse() async throws -> VMCommandResponse? {
        while true {
            if let payload = try decoder.nextFrame() {
                return try JSONDecoder().decode(VMCommandResponse.self, from: Data(payload))
            }
            let descriptor = fd
            let chunk = try await offCooperativePool { () -> Data? in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                guard count > 0 else { return nil }
                return Data(buffer[0..<count])
            }
            guard let chunk else { return nil }  // EOF or error
            decoder.feed(chunk)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
