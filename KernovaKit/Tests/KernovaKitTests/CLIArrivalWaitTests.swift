import ArgumentParser
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// How `clone` and `import` wait for the copy they start: inside the one
/// request that starts it, against a real socket where one is reached.
@Suite("CLI arrival wait", .caseScoped)
struct CLIArrivalWaitTests {
    private func clone(_ arguments: [String]) throws -> KernovaCommand.Clone {
        try #require(try KernovaCommand.parseAsRoot(["clone"] + arguments) as? KernovaCommand.Clone)
    }

    @Test("A clone waits for its copy inside the one request that starts it")
    func cloneWaitsInItsOwnRequest() throws {
        #expect(
            try clone(["Alpha"]).request()
                == .clone(.idOrName("Alpha"), outcome: nil, waitForOutcome: true))
    }

    @Test("--no-wait asks the app not to wait, rather than skipping a second request")
    func noWaitAsksForNoWait() throws {
        #expect(
            try clone(["Alpha", "--no-wait", "--exact-copy"]).request()
                == .clone(.idOrName("Alpha"), outcome: .exactCopy, waitForOutcome: false))
    }

    @Test("An import waits in its one request, and --timeout bounds that request end to end")
    func importDeadlineBoundsTheOneRequest() throws {
        let source = "/Users/somebody/Alpha.kernova"
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        // The app took the request and has not come back to it — the copy is
        // still running, or the permission panel on a mistyped path is up.
        listener.serve([], holdingOpen: true)

        do {
            // The deadline is the assertion here, so it is the one place a
            // small injected timeout is the correct value.
            _ = try PreparingCopy.importing(source, waitingForTheCopy: true, within: 1, on: client)
            Issue.record("expected the import to give up at its deadline")
        } catch let failure as CLIFailure {
            #expect(failure.code == .timedOut)
            #expect(failure.message.contains("was not imported within 1 seconds"))
        }

        // Ends the double's held-open read the way the tool exiting would.
        client.close()
        #expect(try listener.requests().map(\.verb) == [.importVM(path: source, waitForOutcome: true)])
    }
}
