import Darwin
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// The app's request to be brought forward, as the tool meets it on a real
/// socket: answered by pid, and never mistaken for the verb's answer.
@Suite("CLI activation", .caseScoped)
struct CLIActivationTests {
    /// The pids the client asked to bring forward, in order.
    private final class Activations {
        var pids: [pid_t] = []
    }

    private let alpha = VMSummary(
        id: UUID(), name: "Alpha", status: "running", ipAddress: .unavailable, heldByAnotherCopy: false)

    /// Sends `reveal` to a double answering `frames`, recording every activation.
    private func reveal(
        answering frames: [VMCommandResponse]
    ) throws -> (answer: VMCommandResponse, activations: [pid_t]) {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let activations = Activations()
        let client = try VMCommandClient(
            socketPath: listener.path, activate: { activations.pids.append($0) })
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([frames])

        let answer = try client.send(.reveal(.id(alpha.id)))
        return (answer, activations.pids)
    }

    @Test("A frame reader never sees an activate frame, only what follows it")
    func nextFrameReadsPastActivate() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let activations = Activations()
        let client = try VMCommandClient(
            socketPath: listener.path, activate: { activations.pids.append($0) })
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[VMCommandResponse(result: .activate), VMCommandResponse(result: .ok)]])

        try client.post(.open(.id(alpha.id)))

        #expect(try client.nextFrame()?.result == .ok)
        #expect(activations.pids == [getpid()])
    }
}
