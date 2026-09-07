import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What `clone` and `import` do with the row they are answered with while the
/// copy behind it is still being written, against a real socket.
@Suite("CLI preparing wait", .admissionGated)
struct CLIPreparingWaitTests {
    private let phantom = VMSummary(
        id: UUID(uuidString: "44444444-5555-6666-7777-888888888888") ?? UUID(),
        name: "Alpha copy", status: "preparing", ipAddress: .unavailable)

    private var settled: VMSummary {
        VMSummary(
            id: phantom.id, name: "Alpha copy", status: "stopped", ipAddress: .unavailable)
    }

    @Test("The wait is keyed on the row the copy answered with, not on what the caller typed")
    func theWaitNamesThePhantomsIdentifier() throws {
        let listener = try TestCommandSocket(tag: "prep")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([VMCommandResponse(result: .summary(settled))])

        #expect(try PreparingCopy.settle(phantom, on: client) == settled)
        // `.id`, not the name or the text a caller typed: a clone's source
        // answers to that text too, and it is not the row being waited for.
        #expect(listener.requests().map(\.verb) == [.awaitPreparing(.id(phantom.id))])
    }

    @Test("A copy that failed reaches the caller as its own refusal, never as a success")
    func aFailedCopySurfacesItsRefusal() throws {
        let listener = try TestCommandSocket(tag: "prep-fail")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([
            VMCommandResponse(
                result: .failure(
                    .operationFailed(
                        verb: .awaitPreparing, title: nil, message: "The import was cancelled.",
                        recovery: nil)))
        ])

        do {
            _ = try PreparingCopy.settle(phantom, on: client)
            Issue.record("expected the copy's own refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .operationFailed)
            #expect(failure.message == "The import was cancelled.")
        }
    }

    @Test("An answer of the wrong shape refuses rather than being printed as a row")
    func anUnexpectedAnswerRefuses() throws {
        let listener = try TestCommandSocket(tag: "prep-shape")
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve([VMCommandResponse(result: .ok)])

        do {
            _ = try PreparingCopy.settle(phantom, on: client)
            Issue.record("expected an unavailable refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .unavailable)
        }
    }
}
