import Foundation
import KernovaCommandModel
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

@Suite("CLI socket double", .caseScoped)
struct CLISocketDoubleTests {
    @Test("Closing the double hangs up on a client that is still connected")
    func closeEndsAReadParkedOnAnOpenClient() async throws {
        let listener = try TestCommandSocket()
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[VMCommandResponse(result: .ok)]], holdingOpen: true)
        try client.post(.quit)
        // Answered, so the serve loop has accepted and is now reading for a
        // request that never comes.
        #expect(try client.nextFrame()?.result == .ok)

        let closed = Locked(false)
        let gate = AsyncGate()
        DispatchQueue.global().async {
            listener.close()
            closed.withLock { $0 = true }
            gate.notify()
        }
        try await gate.wait { closed.withLock { $0 } }
        #expect(try client.nextFrame() == nil)
    }
}
