import ArgumentParser
import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// A one-connection `AF_UNIX` server standing in for Kernova's command socket.
///
/// Reads the requests the tool writes and answers each with the next canned
/// response, then closes — the hang-up a process exiting produces. Every
/// request is recorded, so a test can assert what the tool actually asked for
/// and not only what it did with the answer.
final class TestCommandSocket: @unchecked Sendable {
    /// Where this server listens.
    let path: String

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "test.kernova.command-socket")
    private var received: [VMCommandRequest] = []
    private var accepted: Int32?
    private var isClosed = false

    /// Binds a listening socket under a short path — `sockaddr_un.sun_path`
    /// holds 104 bytes, which a temporary directory plus a full UUID overruns.
    init(tag: String) throws {
        let short = UUID().uuidString.prefix(8).lowercased()
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("knv-\(tag)-\(short).sock")
        unlink(path)
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

    /// How long the accepted connection waits for a frame before giving up.
    ///
    /// This loop owns ``queue``, which ``requests()`` and ``close()`` both
    /// enter synchronously, so a read with nothing coming would take the whole
    /// test process down with it. Sized far past the microseconds a test's own
    /// frames take, so it only ever fires on a test that queued a response the
    /// tool never asks for — which then fails on `requests()` instead of
    /// hanging.
    private static let readDeadline = timeval(tv_sec: 5, tv_usec: 0)

    /// Accepts the pending client and answers its requests with `responses` in
    /// order, closing once they run out.
    ///
    /// `holdingOpen: true` keeps the connection after the responses do run out,
    /// recording what else arrives and answering none of it — the app that
    /// takes a request and never gets back to it, which is what a caller's own
    /// deadline is for.
    ///
    /// A request that cannot be decoded is still answered, so a test never
    /// hangs on the shape of what it sent.
    func serve(_ responses: [VMCommandResponse], holdingOpen: Bool = false) {
        queue.async { [self] in
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            accepted = connection
            var deadline = Self.readDeadline
            _ = setsockopt(
                connection, SOL_SOCKET, SO_RCVTIMEO, &deadline,
                socklen_t(MemoryLayout<timeval>.size))
            var remaining = responses[...]
            var decoder = StreamFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !remaining.isEmpty || holdingOpen {
                if let frame = (try? decoder.nextFrame()) ?? nil {
                    if let request = try? JSONDecoder().decode(
                        VMCommandRequest.self, from: Data(frame))
                    {
                        received.append(request)
                    }
                    guard !remaining.isEmpty else { continue }
                    Self.write(remaining.removeFirst(), to: connection)
                    continue
                }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(connection, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }  // the client hung up, or the deadline
                decoder.feed(Data(buffer[0..<count]))
            }
            Darwin.close(connection)
            accepted = nil
        }
    }

    /// What the tool asked for, in the order it asked.
    func requests() -> [VMCommandRequest] {
        queue.sync { received }
    }

    /// Closes the listener and any connection it accepted; idempotent.
    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            if let accepted { Darwin.close(accepted) }
            Darwin.close(descriptor)
            unlink(path)
        }
    }

    private static func write(_ response: VMCommandResponse, to connection: Int32) {
        guard let payload = try? JSONEncoder().encode(response),
            let framed = try? StreamFrame.encode(payload)
        else { return }
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
        _ arguments: [String], answering response: VMCommandResponse, tag: String
    ) throws -> (sent: [VMCommandRequest.Verb], answer: VMCommandResponse) {
        let command = try #require(
            try KernovaCommand.parseAsRoot(arguments) as? any VerbCommand,
            "\(arguments) did not parse to a command that builds its own request")
        let request = try command.verb()

        let listener = try TestCommandSocket(tag: tag)
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([response])

        let answer = try client.send(request)
        return (listener.requests().map(\.verb), answer)
    }
}
