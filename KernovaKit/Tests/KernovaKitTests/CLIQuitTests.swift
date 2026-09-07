import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// `kernova quit` against a real socket: the tool has to stay until the app has
/// gone, not until the app has said it will go.
@Suite("CLI quit", .admissionGated)
struct CLIQuitTests {
    @Test("The tool returns from a quit only once the app closes the connection")
    func quitWaitsForTheConnectionToClose() throws {
        let listener = try TestCommandSocket(tag: "quit")
        defer { listener.close() }

        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)

        // The app answers `ok`, runs its save pass, and only then exits — which
        // is the close the tool is waiting for.
        listener.serve([VMCommandResponse(result: .ok)])
        try client.post(.quit)

        let answer = try client.nextFrame()
        #expect(answer?.result == .ok)
        try KernovaCommand.Quit.outcome(for: answer)

        // Blocking, and safe to block this thread: what ends the wait is the
        // peer closing the socket, which the server queue has already done —
        // nothing it needs runs on an actor this call could be starving. The
        // socket's own receive deadline is the backstop.
        #expect(throws: Never.self) { try KernovaCommand.Quit.awaitExit(of: client) }
        #expect(listener.requests().map(\.verb) == [.quit])
    }
}
