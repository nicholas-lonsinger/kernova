import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What `kernova wait` does with the frames a subscription delivers, against a
/// real socket.
@Suite("CLI wait", .admissionGated)
struct CLIWaitTests {
    private let alpha = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
    private let beta = UUID(uuidString: "99999999-8888-7777-6666-555555555555") ?? UUID()

    /// What the tool asks for, in order, whatever the wait ends on.
    private let subscribeThenRead: [VMCommandRequest.Verb] = [
        .events, .info(.idOrName("Alpha")),
    ]

    // MARK: - A Failure Ends the Wait

    @Test("A failure reported while the wait runs ends it carrying Kernova's own message")
    func aFailureEndsTheWaitWithItsMessage() throws {
        let ended = try outcome(
            .running, tag: "wait-fail",
            answering: [
                info(status: "installing"),
                event(.failure(id: alpha, name: "Alpha", message: "The install could not run.")),
            ])
        #expect(ended.failure?.code == .operationFailed)
        #expect(ended.failure?.message == "The install could not run.")
        #expect(ended.verbs == subscribeThenRead)
    }

    @Test("The status change into error ahead of the failure does not cost the message")
    func theStatusChangeIntoErrorDoesNotCostTheMessage() throws {
        // The order the app emits them in: one batch carrying the status change
        // and the failure behind it, so a wait that settled for the first frame
        // would report a failure it could not explain.
        let ended = try outcome(
            .running, tag: "wait-error-status",
            answering: [
                info(status: "installing"),
                event(.statusChanged(id: alpha, name: "Alpha", from: "installing", to: "error")),
                event(.failure(id: alpha, name: "Alpha", message: "The guest never booted.")),
            ])
        #expect(ended.failure?.code == .operationFailed)
        #expect(ended.failure?.message == "The guest never booted.")
    }

    @Test("A failure that reaches the wire ahead of the info answer ends the wait too")
    func aFailureAheadOfTheInfoAnswerEndsTheWait() throws {
        let ended = try outcome(
            .agent, tag: "wait-fail-early",
            answering: [
                event(.failure(id: alpha, name: "Alpha", message: "The disk went away.")),
                info(status: "running"),
            ])
        #expect(ended.failure?.code == .operationFailed)
        #expect(ended.failure?.message == "The disk went away.")
    }

    @Test("A virtual machine that leaves the library ends the wait")
    func aRemovedVirtualMachineEndsTheWait() throws {
        let ended = try outcome(
            .stopped, tag: "wait-removed",
            answering: [info(status: "running"), event(.removed(id: alpha, name: "Alpha"))])
        #expect(ended.failure?.code == .notFound)
        #expect(ended.failure?.message == "\u{201C}Alpha\u{201D} left the library.")
    }

    // MARK: - Another Virtual Machine's Events

    @Test("A failure naming another virtual machine is not this wait's")
    func anotherVirtualMachinesFailureIsIgnored() throws {
        let ended = try outcome(
            .running, tag: "wait-other-vm",
            answering: [
                info(status: "stopped"),
                event(.failure(id: beta, name: "Beta", message: "Beta's disk went away.")),
                event(.statusChanged(id: beta, name: "Beta", from: "starting", to: "error")),
                event(.removed(id: beta, name: "Beta")),
                event(.statusChanged(id: alpha, name: "Alpha", from: "starting", to: "running")),
            ])
        #expect(ended.failure == nil)
        #expect(ended.verbs == subscribeThenRead)
    }

    // MARK: - An Error Found at the Start

    @Test("A virtual machine already in the error status when the wait starts keeps it waiting")
    func anErrorInTheBaselineKeepsTheWaitRunning() throws {
        // The failure behind it happened before this wait, and the virtual
        // machine can be started from there, so nothing here says the state
        // being waited for is not coming. Ending on the event *after* that
        // baseline is what proves the wait read it and went on.
        let ended = try outcome(
            .running, tag: "wait-resting-error",
            answering: [
                info(status: "error"),
                event(.statusChanged(id: alpha, name: "Alpha", from: "error", to: "running")),
            ])
        #expect(ended.failure == nil)
        #expect(ended.verbs == subscribeThenRead)
    }

    // MARK: - Reaching the State

    @Test("A virtual machine already in the state ends the wait on the snapshot")
    func theBaselineEndsTheWait() throws {
        let ended = try outcome(.running, tag: "wait-baseline", answering: [info(status: "running")])
        #expect(ended.failure == nil)
        #expect(ended.verbs == subscribeThenRead)
    }

    @Test("The status the wait names ends it when it arrives as an event")
    func aStatusEventEndsTheWait() throws {
        let ended = try outcome(
            .stopped, tag: "wait-status",
            answering: [
                info(status: "running"),
                event(.statusChanged(id: alpha, name: "Alpha", from: "running", to: "stopped")),
            ])
        #expect(ended.failure == nil)
    }

    @Test("A current agent ends an agent wait")
    func theAgentConditionEndsOnACurrentAgent() throws {
        let ended = try outcome(
            .agent, tag: "wait-agent",
            answering: [
                info(status: "running", agentStatus: "outdated"),
                event(.agentStatusChanged(id: alpha, name: "Alpha", status: "current")),
            ])
        #expect(ended.failure == nil)
    }

    // MARK: - The Deadline

    @Test("The deadline ends a wait nothing else does, naming what was waited for")
    func theDeadlineEndsTheWait() throws {
        // The deadline is the assertion here, so it is the one place a small
        // injected timeout is the correct value.
        let ended = try outcome(
            .running, tag: "wait-deadline", timeout: 1,
            answering: [info(status: "stopped")], holdingOpen: true)
        #expect(ended.failure?.code == .timedOut)
        #expect(ended.failure?.message == "\u{201C}Alpha\u{201D} was not running within 1 seconds.")
    }

    // MARK: - Fixtures

    /// How a wait ended, and what it asked for on the way.
    private typealias WaitOutcome = (failure: CLIFailure?, verbs: [VMCommandRequest.Verb])

    /// Runs one wait against a double that answers the subscription with the
    /// library as it stands and the `info` request with `frames`, in order.
    ///
    /// `frames` carries the `info` answer and every event behind it, so a test
    /// places an event before or after that answer to choose which of the two
    /// the tool reads first.
    private func outcome(
        _ until: WaitCondition, tag: String, timeout: Double = testWaitBackstop,
        answering frames: [VMCommandResponse], holdingOpen: Bool = false
    ) throws -> WaitOutcome {
        let listener = try TestCommandSocket(tag: tag)
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        listener.serve([[snapshot], frames], holdingOpen: holdingOpen)

        var ended: CLIFailure?
        do {
            try StateWait(selector: .idOrName("Alpha"), until: until, timeout: timeout)
                .run(on: client)
        } catch let failure as CLIFailure {
            ended = failure
        }
        // Ends the double's held-open read the way the tool exiting would, so
        // reading what it received is not queued behind that read.
        client.close()
        return (ended, listener.requests().map(\.verb))
    }

    /// The library the subscription answers with before any event.
    private var snapshot: VMCommandResponse {
        VMCommandResponse(
            result: .summaries([
                VMSummary(id: alpha, name: "Alpha", status: "stopped", ipAddress: .unavailable)
            ]))
    }

    private func info(status: String, agentStatus: String = "absent") -> VMCommandResponse {
        VMCommandResponse(
            result: .info(
                VMInfo(
                    id: alpha, name: "Alpha", status: status, guestOS: "macOS", cpuCount: 4,
                    memoryBytes: 8 * 1024 * 1024 * 1024, diskSizeInGB: 64, networkMode: "shared",
                    macAddress: nil, ipAddress: .unavailable, agentStatus: agentStatus,
                    hasSavedState: false, isEphemeral: false, snapshotCount: 0,
                    bundlePath: "/Users/somebody/Alpha.kernova")))
    }

    private func event(_ event: VMLibraryEvent) -> VMCommandResponse {
        VMCommandResponse(result: .event(event))
    }
}
