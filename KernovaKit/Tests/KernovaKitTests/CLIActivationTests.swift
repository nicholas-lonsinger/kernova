import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// The app's request to be brought forward, as the tool meets it on a real
/// socket: answered by pid, and never mistaken for the verb's answer.
@Suite("CLI activation", .admissionGated)
struct CLIActivationTests {
    /// The pids the client asked to bring forward, in order.
    private final class Activations {
        var pids: [pid_t] = []
    }

    private let alpha = VMSummary(
        id: UUID(), name: "Alpha", status: "running", ipAddress: .unavailable)

    /// Sends `reveal` to a double answering `frames`, recording every activation.
    private func reveal(
        answering frames: [VMCommandResponse], tag: String
    ) throws -> (answer: VMCommandResponse, activations: [pid_t]) {
        let listener = try TestCommandSocket(tag: tag)
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

    @Test("An activate frame ahead of the answer brings the peer forward, and the answer still arrives")
    func activateFrameCallsTheActivatorWithThePeer() throws {
        let exchanged = try reveal(
            answering: [VMCommandResponse(result: .activate), VMCommandResponse(result: .ok)],
            tag: "activate")

        #expect(exchanged.answer.result == .ok)
        // The double runs in this process, so the peer is this process.
        #expect(exchanged.activations == [getpid()])
    }

    @Test("An answer with no activate frame brings nothing forward")
    func noActivateFrameNoActivation() throws {
        let exchanged = try reveal(answering: [VMCommandResponse(result: .ok)], tag: "noactivate")

        #expect(exchanged.answer.result == .ok)
        #expect(exchanged.activations.isEmpty)
    }

    @Test("A frame reader never sees an activate frame, only what follows it")
    func nextFrameReadsPastActivate() throws {
        let listener = try TestCommandSocket(tag: "frames")
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
