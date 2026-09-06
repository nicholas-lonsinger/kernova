import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// `kernova quit` against a real socket: the tool has to stay until the app has
/// gone, not until the app has said it will go.
@Suite("CLI quit", .admissionGated)
struct CLIQuitTests {
    /// A short path: `sockaddr_un.sun_path` holds 104 bytes.
    private func temporarySocketPath() -> String {
        let short = UUID().uuidString.prefix(8).lowercased()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("knv-q-\(short).sock")
    }

    @Test("The tool returns from a quit only once the app closes the connection")
    func quitWaitsForTheConnectionToClose() throws {
        let path = temporarySocketPath()
        let listener = try TestSocketServer(path: path)
        defer { listener.close() }

        let client = try VMCommandClient(socketPath: path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)

        // The app answers `ok`, runs its save pass, and only then exits — which
        // is the close the tool is waiting for.
        try client.post(.quit)
        listener.answerThenHangUp(VMCommandResponse(result: .ok))

        let answer = try client.nextFrame()
        #expect(answer?.result == .ok)
        try KernovaCommand.Quit.outcome(for: answer)

        // Blocking, and safe to block this thread: what ends the wait is the
        // peer closing the socket, which the server queue has already done —
        // nothing it needs runs on an actor this call could be starving. The
        // socket's own receive deadline is the backstop.
        #expect(throws: Never.self) { try KernovaCommand.Quit.awaitExit(of: client) }
    }
}

/// A one-connection `AF_UNIX` server, for driving the client end of a quit.
private final class TestSocketServer: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "test.kernova.quit-server")
    private var accepted: Int32?
    private var isClosed = false

    init(path: String) throws {
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

    /// Accepts the pending client, writes one framed response, then closes —
    /// the hang-up a process exiting produces.
    func answerThenHangUp(_ response: VMCommandResponse) {
        queue.async { [self] in
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            accepted = connection
            if let payload = try? JSONEncoder().encode(response),
                let framed = try? StreamFrame.encode(payload)
            {
                framed.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = write(connection, base, raw.count)
                }
            }
            Darwin.close(connection)
            accepted = nil
        }
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            if let accepted { Darwin.close(accepted) }
            Darwin.close(descriptor)
        }
    }
}
