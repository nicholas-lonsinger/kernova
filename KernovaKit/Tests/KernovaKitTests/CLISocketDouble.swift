import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport

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

    /// Accepts the pending client and answers its requests with `responses` in
    /// order, closing once they run out.
    ///
    /// A request that cannot be decoded is still answered, so a test never
    /// hangs on the shape of what it sent.
    func serve(_ responses: [VMCommandResponse]) {
        queue.async { [self] in
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            accepted = connection
            var remaining = responses[...]
            var decoder = StreamFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !remaining.isEmpty {
                if let frame = (try? decoder.nextFrame()) ?? nil {
                    if let request = try? JSONDecoder().decode(
                        VMCommandRequest.self, from: Data(frame))
                    {
                        received.append(request)
                    }
                    Self.write(remaining.removeFirst(), to: connection)
                    continue
                }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(connection, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }
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
