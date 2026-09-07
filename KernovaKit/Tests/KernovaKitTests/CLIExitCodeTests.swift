import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// Every refusal the tool can receive maps to exactly one exit code, and the
/// mapping is exhaustive by `switch` — a new refusal case will not compile
/// until it has a code.
@Suite("CLI exit codes", .admissionGated)
struct CLIExitCodeTests {
    private let vm = VMSummary(
        id: UUID(), name: "Alpha", status: "running", ipAddress: .unavailable)

    @Test("Every verb refusal takes its own code")
    func everyCommandErrorMaps() {
        let expected: [(CommandErrorDTO, CLIExitCode)] = [
            (.notFound(selector: .idOrName("Alpha")), .notFound),
            (.ambiguous(selector: .idOrName("Alpha"), candidates: [vm]), .ambiguous),
            (.invalidState(vm: vm, current: "running", allowed: [.stop]), .refusedByState),
            (.unsupported(capability: "snapshots"), .refusedByState),
            (.conflict(vm: vm, with: vm, reason: .macAddress), .refusedByState),
            (
                .confirmationRequired(
                    prompt: ConfirmationPrompt(
                        kind: .forceStop, title: "Force Stop?", message: "State is lost.",
                        confirmTitle: "Force Stop", dismissTitle: "Cancel")),
                .refusedByState
            ),
            (.busy(vm: vm, operation: "starting"), .busy),
            (.timedOut(vm: vm, verb: .stop, seconds: 60), .timedOut),
            (
                .operationFailed(verb: .start, title: nil, message: "no disk", recovery: nil),
                .operationFailed
            ),
        ]
        for (failure, code) in expected {
            #expect(CLIExitCode(failure) == code, "\(failure)")
        }
    }

    @Test("Every envelope refusal takes its own code")
    func everyTransportRefusalMaps() {
        #expect(
            CLIExitCode(.authorizationRefused(reason: "not this team")) == .authorizationRefused)
        #expect(CLIExitCode(.unsupportedProtocolVersion(peer: 2, expected: 1)) == .unavailable)
        #expect(CLIExitCode(.undecodableRequest("bad bytes")) == .unavailable)
    }

    @Test("No two codes collide, and success is zero")
    func codesAreDistinct() {
        #expect(CLIExitCode.success.rawValue == 0)
        #expect(Set(CLIExitCode.allCases.map(\.rawValue)).count == CLIExitCode.allCases.count)
        // ArgumentParser's own EX_USAGE must never escape as one of ours.
        #expect(!CLIExitCode.allCases.map(\.rawValue).contains(64))
    }

    @Test("A quit is a success even when the app hangs up instead of answering")
    func quitTreatsEndOfStreamAsSuccess() {
        // The app encodes `ok` before it starts going down, but the process it
        // was asked to leave is leaving: a closed connection is the quit
        // happening, not a failure.
        #expect(throws: Never.self) { try KernovaCommand.Quit.outcome(for: nil) }
        #expect(throws: Never.self) {
            try KernovaCommand.Quit.outcome(for: VMCommandResponse(result: .ok))
        }
    }

    @Test("A quit the app refuses exits with the refusal's own code")
    func quitReportsARefusal() {
        let refused = VMCommandResponse(
            result: .refused(.authorizationRefused(reason: "not this team")))
        do {
            try KernovaCommand.Quit.outcome(for: refused)
            Issue.record("expected an authorization refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .authorizationRefused)
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }

    @Test("A refused answer becomes the failure the tool exits with")
    func responsePayloadThrowsTheRefusal() throws {
        let refused = VMCommandResponse(result: .failure(.notFound(selector: .idOrName("Ghost"))))
        #expect(throws: CLIFailure.self) { try refused.payload() }

        let authorization = VMCommandResponse(
            result: .refused(.authorizationRefused(reason: "wrong team")))
        do {
            _ = try authorization.payload()
            Issue.record("expected a refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .authorizationRefused)
            #expect(failure.message == "wrong team")
        }
    }

    @Test("A successful answer hands its payload back untouched")
    func responsePayloadReturnsTheResult() throws {
        let listing = VMCommandResponse(result: .summaries([vm]))
        #expect(try listing.payload() == .summaries([vm]))
        #expect(try VMCommandResponse(result: .ok).payload() == .ok)
    }
}
