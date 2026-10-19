import ArgumentParser
import Darwin
import Foundation
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// A one-connection `AF_UNIX` server standing in for Kernova's command socket.
///
/// Reads the requests the tool writes and answers each with the next canned
/// response, then closes — the hang-up a process exiting produces. Every
/// request is recorded, so a test can assert what the tool actually asked for
/// and not only what it did with the answer.
final class TestCommandSocket: Sendable {
    /// Where this server listens.
    let path: String

    private let descriptor: Int32

    /// Runs the serve loop; ``requests()`` and ``close()`` wait behind it.
    private let queue = DispatchQueue(label: "test.kernova.command-socket")

    private struct State: Sendable {
        var received: [VMCommandRequest] = []
        var accepted: Int32?
        var isClosed = false
    }

    private let state = Locked(State())

    /// Binds a listening socket in a scratch directory of its own, under a
    /// short leaf — `sockaddr_un.sun_path` holds 104 bytes.
    init() throws {
        let scratch = TestScratchDirectory(prefix: "knv")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        path = scratch.url.appendingPathComponent("c.sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure("server socket() failed: errno \(errno)") }
        var address = try UnixSocketAddress.make(path: path)
        let bound = UnixSocketAddress.withSockaddr(&address) { socketAddress, length in
            bind(descriptor, socketAddress, length)
        }
        guard bound == 0 else { throw TestFailure("server bind() failed: errno \(errno)") }
        guard listen(descriptor, 1) == 0 else {
            throw TestFailure("server listen() failed: errno \(errno)")
        }
    }

    /// Accepts the pending client and answers its requests with `groups` in
    /// order, closing once they run out.
    ///
    /// The Nth request is answered with every response in the Nth group, in the
    /// order written — which is how a subscription's answer and the event
    /// frames behind it both reach a client that sent one request for them.
    ///
    /// `holdingOpen: true` keeps the connection after the groups do run out,
    /// recording what else arrives and answering none of it — the app that
    /// takes a request and never gets back to it, which is what a caller's own
    /// deadline is for.
    ///
    /// A request that cannot be decoded is still answered, so a test never
    /// hangs on the shape of what it sent.
    func serve(_ groups: [[VMCommandResponse]], holdingOpen: Bool = false) {
        serveFrames(
            groups.map { $0.map { (try? JSONEncoder().encode($0)) ?? Data() } },
            holdingOpen: holdingOpen)
    }

    /// ``serve(_:holdingOpen:)`` with each answer as the raw JSON payload of
    /// its frame — for an app whose vocabulary this build cannot spell.
    func serveFrames(_ groups: [[Data]], holdingOpen: Bool = false) {
        queue.async { [self] in
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            let isOpen = state.withLock { state in
                if !state.isClosed { state.accepted = connection }
                return !state.isClosed
            }
            guard isOpen else {
                Darwin.close(connection)
                return
            }
            var remaining = groups[...]
            var decoder = StreamFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !remaining.isEmpty || holdingOpen {
                if let frame = (try? decoder.nextFrame()) ?? nil {
                    if let request = try? JSONDecoder().decode(
                        VMCommandRequest.self, from: Data(frame))
                    {
                        state.withLock { $0.received.append(request) }
                    }
                    guard !remaining.isEmpty else { continue }
                    for response in remaining.removeFirst() {
                        Self.write(response, to: connection)
                    }
                    continue
                }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(connection, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }  // the client hung up, or close() shut it down
                decoder.feed(Data(buffer[0..<count]))
            }
            state.withLock { $0.accepted = nil }
            Darwin.close(connection)
        }
    }

    /// What the tool asked for, in the order it asked, once the serve loop
    /// has ended — the groups ran out or the client hung up.
    ///
    /// Throws at ``testWaitBackstop`` when the loop is still reading: a test
    /// that queued an answer the tool never asks for, or held the connection
    /// open without closing its client first.
    func requests() throws -> [VMCommandRequest] {
        let stopwatch = BackstopStopwatch()
        let loopEnded = DispatchSemaphore(value: 0)
        queue.async { loopEnded.signal() }
        guard loopEnded.wait(timeout: .now() + testWaitBackstop) == .success else {
            throw TestFailure.backstop(
                "The command socket double was still reading",
                stopwatch: stopwatch, timeout: testWaitBackstop)
        }
        return state.withLock { $0.received }
    }

    /// Closes the listener and any connection it accepted; idempotent.
    ///
    /// Shutting the accepted connection down ends a read parked on it, so the
    /// serve loop this waits behind returns once a client has connected.
    func close() {
        let wasOpen = state.withLock { state in
            defer { state.isClosed = true }
            if let accepted = state.accepted { shutdown(accepted, SHUT_RDWR) }
            return !state.isClosed
        }
        guard wasOpen else { return }
        queue.sync {
            Darwin.close(descriptor)
            unlink(path)
        }
    }

    private static func write(_ payload: Data, to connection: Int32) {
        guard let framed = try? StreamFrame.encode(payload) else { return }
        framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(connection, base, raw.count)
        }
    }
}

/// One command line's round trip against a socket double.
enum CLIWire {
    /// Sends what `arguments` stand for to a double answering `response`, and
    /// hands back what crossed the wire and what came back.
    ///
    /// The command line is parsed by the root command, so the request is the
    /// one the tool would have sent — only the socket it reaches is the test's.
    static func exchange(
        _ arguments: [String], answering response: VMCommandResponse
    ) throws -> (sent: [VMCommandRequest.Verb], answer: VMCommandResponse) {
        let command = try #require(
            try KernovaCommand.parseAsRoot(arguments) as? any VerbCommand,
            "\(arguments) did not parse to a command that builds its own request")
        let request = try command.verb()

        let listener = try TestCommandSocket()
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[response]])

        let answer = try client.send(request)
        return (try listener.requests().map(\.verb), answer)
    }
}
