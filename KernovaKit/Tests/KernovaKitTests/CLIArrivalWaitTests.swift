import ArgumentParser
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// How `clone` and `import` wait for the copy they start: inside the one
/// request that starts it, against a real socket where one is reached.
@Suite("CLI arrival wait", .admissionGated)
struct CLIArrivalWaitTests {
    private let settled = VMSummary(
        id: UUID(uuidString: "44444444-5555-6666-7777-888888888888") ?? UUID(),
        name: "Alpha copy", status: "stopped", ipAddress: .unavailable)

    private func clone(_ arguments: [String]) throws -> KernovaCommand.Clone {
        try #require(try KernovaCommand.parseAsRoot(["clone"] + arguments) as? KernovaCommand.Clone)
    }

    @Test("A clone waits for its copy inside the one request that starts it")
    func cloneWaitsInItsOwnRequest() throws {
        #expect(
            try clone(["Alpha"]).request()
                == .clone(.idOrName("Alpha"), machineIdentity: .followPreference, waitForOutcome: true))
    }

    @Test("--no-wait asks the app not to wait, rather than skipping a second request")
    func noWaitAsksForNoWait() throws {
        #expect(
            try clone(["Alpha", "--no-wait", "--keep-identity"]).request()
                == .clone(.idOrName("Alpha"), machineIdentity: .keep, waitForOutcome: false))
    }

    @Test("An import waits in its one request, and --timeout bounds that request end to end")
    func importDeadlineBoundsTheOneRequest() throws {
        let source = "/Users/somebody/Alpha.kernova"
        let listener = try TestCommandSocket(tag: "arrival-deadline")
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
        #expect(listener.requests().map(\.verb) == [.importVM(path: source, waitForOutcome: true)])
    }

    @Test("A waited import answers the settled row from its one request")
    func aWaitedImportAnswersTheSettledRow() throws {
        let source = "/Users/somebody/Alpha.kernova"
        let listener = try TestCommandSocket(tag: "arrival-settled")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[VMCommandResponse(result: .summary(settled))]])

        #expect(
            try PreparingCopy.importing(source, waitingForTheCopy: true, within: nil, on: client)
                == settled)
        #expect(listener.requests().map(\.verb) == [.importVM(path: source, waitForOutcome: true)])
    }

    @Test("A copy that failed reaches the caller as its own refusal, never as a success")
    func aFailedCopySurfacesItsRefusal() throws {
        let listener = try TestCommandSocket(tag: "arrival-fail")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([
            [
                VMCommandResponse(
                    result: .failure(
                        .operationFailed(
                            verb: .importVM, title: nil, message: "The bundle could not be read.",
                            recovery: nil)))
            ]
        ])

        do {
            _ = try PreparingCopy.importing(
                "/Users/somebody/Alpha.kernova", waitingForTheCopy: true, within: nil, on: client)
            Issue.record("expected the copy's own refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .operationFailed)
            #expect(failure.message == "The bundle could not be read.")
        }
    }

    @Test("An answer of the wrong shape refuses rather than being printed as a row")
    func anUnexpectedAnswerRefuses() throws {
        let listener = try TestCommandSocket(tag: "arrival-shape")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([[VMCommandResponse(result: .ok)]])

        do {
            _ = try PreparingCopy.importing(
                "/Users/somebody/Alpha.kernova", waitingForTheCopy: false, within: nil, on: client)
            Issue.record("expected an unavailable refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .unavailable)
        }
    }
}
