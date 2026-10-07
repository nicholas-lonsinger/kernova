import ArgumentParser
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// `kernova start|suspend|stop --smart-group|--folder`: what the line means,
/// what crosses the wire, what is printed, and what the tool exits with.
@Suite("CLI group actions", .caseScoped)
struct CLIGroupActionTests {
    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try KernovaCommand.parseAsRoot(arguments)
    }

    private func summary(_ name: String, status: String = "running") -> VMSummary {
        VMSummary(id: UUID(), name: name, status: status, ipAddress: .unavailable, heldByAnotherCopy: false)
    }

    /// One VM of each outcome a group start can report, in that order.
    private var mixedReport: VMGroupActionReport {
        let prompt = ConfirmationPrompt(
            kind: .startBesideSharedMachineIdentity, title: "Start \u{201C}Twin\u{201D} Anyway?",
            message: "\u{201C}Twin\u{201D} has the same machine ID as \u{201C}Live\u{201D}, which is active.",
            confirmTitle: "Start Anyway", dismissTitle: "Cancel")
        return VMGroupActionReport(
            action: .start, groupKind: .folder, groupID: UUID(), groupName: "Lab",
            results: [
                VMGroupActionResult(vm: summary("Web"), outcome: .done(verb: .start)),
                VMGroupActionResult(vm: summary("Paused"), outcome: .done(verb: .resume)),
                VMGroupActionResult(vm: summary("Up"), outcome: .passedOver(reason: .state)),
                VMGroupActionResult(
                    vm: summary("Fresh", status: "initialBoot"), outcome: .passedOver(reason: .guestSetup)),
                VMGroupActionResult(
                    vm: summary("Twin", status: "stopped"),
                    outcome: .needsAnswer(verb: .start, question: .confirmationRequired(prompt: prompt))),
                VMGroupActionResult(
                    vm: summary("Third", status: "stopped"),
                    outcome: .failed(
                        error: .operationFailed(
                            verb: .start, title: nil, message: "macOS allows at most two.", recovery: nil))),
            ])
    }

    // MARK: - Parsing

    @Test("start, suspend and stop take a group in place of a VM, and send one group action")
    func groupTargetsParse() throws {
        let cases: [([String], VMCommandRequest.Verb)] = [
            (["start", "--folder", "Lab"], .groupAction(.start, group: VMGroupReference(.folder, named: "Lab"))),
            (
                ["suspend", "--smart-group", "Linux Lab"],
                .groupAction(.suspend, group: VMGroupReference(.smartGroup, named: "Linux Lab"))
            ),
            (["stop", "--folder", "Lab"], .groupAction(.stop, group: VMGroupReference(.folder, named: "Lab"))),
        ]
        for (line, expected) in cases {
            let command = try #require(try parse(line) as? any VerbCommand)
            #expect(try command.verb() == expected, "\(line)")
        }
    }

    @Test("A group is mutually exclusive with <vm>, and one of the two is required")
    func groupAndVMAreExclusive() throws {
        for verb in ["start", "suspend", "stop"] {
            #expect(throws: (any Error).self, "\(verb)") { try parse([verb, "Alpha", "--folder", "Lab"]) }
            #expect(throws: (any Error).self, "\(verb)") { try parse([verb]) }
            #expect(throws: (any Error).self, "\(verb)") {
                try parse([verb, "--folder", "Lab", "--smart-group", "Linux"])
            }
            #expect(try parse([verb, "Alpha"]) is any VerbCommand)
        }
    }

    @Test("A flag that changes one VM's verb is refused beside a group")
    func singleVMFlagsAreRefused() {
        let refused: [[String]] = [
            ["start", "--folder", "Lab", "--recovery"],
            ["start", "--folder", "Lab", "--resolve-mac-conflict", "own-network"],
            ["start", "--folder", "Lab", "--yes"],
            ["stop", "--folder", "Lab", "--force"],
            ["stop", "--folder", "Lab", "--resume-first"],
            ["stop", "--folder", "Lab", "--timeout", "5"],
            ["suspend", "--folder", "Lab", "--yes"],
        ]
        for line in refused {
            #expect(throws: (any Error).self, "\(line)") { try parse(line) }
        }
    }

    @Test("A group start crosses the wire as one request, and its report comes back whole")
    func groupActionCrossesTheWire() throws {
        let report = mixedReport
        let exchanged = try CLIWire.exchange(
            ["start", "--smart-group", "Linux Lab"], answering: VMCommandResponse(result: .groupAction(report)))

        #expect(exchanged.sent == [.groupAction(.start, group: VMGroupReference(.smartGroup, named: "Linux Lab"))])
        #expect(try exchanged.answer.payload() == .groupAction(report))
    }

    // MARK: - Output

    @Test("Text output is one line per VM in the group, saying what was done or why not")
    func textOutputIsOneLinePerVM() throws {
        let text = try GroupActionOutput.render(mixedReport, format: .table, quiet: false)

        #expect(
            text.split(separator: "\n").map(String.init) == [
                "Started Web",
                "Resumed Paused",
                "Skipped Up: it is running.",
                "Skipped Fresh: its first start sets up its guest, which only its own Start begins.",
                "Skipped Twin: \u{201C}Twin\u{201D} has the same machine ID as \u{201C}Live\u{201D}, which is active. "
                    + "Start it on its own to answer.",
                "Couldn\u{2019}t start Third: macOS allows at most two.",
            ])
    }

    @Test("--quiet prints the names of the VMs the action was done to")
    func quietPrintsTheDoneNames() throws {
        #expect(try GroupActionOutput.render(mixedReport, format: .table, quiet: true) == "Web\nPaused")
    }

    @Test("JSON output is the report itself, the wire's own schema")
    func jsonOutputIsTheReport() throws {
        let report = mixedReport
        let json = try GroupActionOutput.render(report, format: .json, quiet: false)

        #expect(try JSONDecoder().decode(VMGroupActionReport.self, from: Data(json.utf8)) == report)
        #expect(json.contains(#""done" : {"#))
        #expect(json.contains(#""needsAnswer" : {"#))
        #expect(json.contains(#""groupName" : "Lab""#))
    }

    @Test("Each outcome encodes in one stable shape: a reason carrying nothing is its bare name")
    func outcomeJSONShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let no = CommandErrorDTO.invalidArgument(message: "No.")
        let expected: [(VMGroupActionOutcome, String)] = [
            (.done(verb: .start), #"{"done":{"verb":"start"}}"#),
            (.passedOver(reason: .state), #"{"passedOver":{"reason":"state"}}"#),
            (.passedOver(reason: .guestSetup), #"{"passedOver":{"reason":"guestSetup"}}"#),
            (.passedOver(reason: .cancelled), #"{"passedOver":{"reason":"cancelled"}}"#),
            (
                .passedOver(reason: .refused(error: no)),
                #"{"passedOver":{"reason":{"refused":{"error":{"invalidArgument":{"message":"No."}}}}}}"#
            ),
            (
                .needsAnswer(verb: .resume, question: no),
                #"{"needsAnswer":{"question":{"invalidArgument":{"message":"No."}},"verb":"resume"}}"#
            ),
            (.failed(error: no), #"{"failed":{"error":{"invalidArgument":{"message":"No."}}}}"#),
        ]
        for (outcome, json) in expected {
            #expect(String(decoding: try encoder.encode(outcome), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(VMGroupActionOutcome.self, from: Data(json.utf8)) == outcome)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMGroupActionOutcome.self, from: Data(#"{"passedOver":{"reason":"busy"}}"#.utf8))
        }

        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let report = VMGroupActionReport(
            action: .stop, groupKind: .smartGroup, groupID: id, groupName: "Running",
            results: [
                VMGroupActionResult(
                    vm: VMSummary(
                        id: id, name: "Web", status: "stopped", ipAddress: .observed("192.168.64.4"),
                        heldByAnotherCopy: false),
                    outcome: .passedOver(reason: .state))
            ])
        let reportJSON = String(decoding: try encoder.encode(report), as: UTF8.self)
        #expect(
            reportJSON
                == #"{"action":"stop","groupID":"11111111-2222-3333-4444-555555555555","groupKind":"smartGroup","#
                + #""groupName":"Running","results":[{"outcome":{"passedOver":{"reason":"state"}},"#
                + #""vm":{"heldByAnotherCopy":false,"id":"11111111-2222-3333-4444-555555555555","#
                + #""ipAddress":{"address":"192.168.64.4","state":"observed"},"name":"Web","status":"stopped"}}]}"#)
    }

    @Test("Stop and suspend word what they did in their own terms")
    func stopAndSuspendLines() {
        let vm = summary("Web")
        #expect(VMGroupActionResult(vm: vm, outcome: .done(verb: .stop)).line(for: .stop) == "Asked Web to shut down")
        #expect(VMGroupActionResult(vm: vm, outcome: .done(verb: .suspend)).line(for: .suspend) == "Suspended Web")
        let paused = VMSummary(
            id: UUID(), name: "Held", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: true)
        #expect(
            VMGroupActionResult(vm: paused, outcome: .passedOver(reason: .state)).line(for: .stop)
                == "Skipped Held: it is in use by another copy of Kernova.")
    }

    @Test("A question is answered by the verb the VM was taken by, and a cancel names the action")
    func questionAndCancelLines() {
        let vm = summary("Twin", status: "suspended")
        let prompt = ConfirmationPrompt(
            kind: .startBesideSharedMachineIdentity, title: "Resume \u{201C}Twin\u{201D} Anyway?",
            message: "Shared.", confirmTitle: "Resume Anyway", dismissTitle: "Cancel")
        let resumed = VMGroupActionResult(
            vm: vm, outcome: .needsAnswer(verb: .resume, question: .confirmationRequired(prompt: prompt)))
        #expect(resumed.line(for: .start) == "Skipped Twin: Shared. Resume it on its own to answer.")
        #expect(
            VMGroupActionResult(vm: vm, outcome: .passedOver(reason: .cancelled)).line(for: .stop)
                == "Skipped Twin: the stop was cancelled before its turn.")
        #expect(!VMGroupActionOutcome.passedOver(reason: .cancelled).isUndone)
    }

    // MARK: - Exit

    @Test("A VM left undone exits 10 naming how many; skipped-by-state and done exit 0")
    func exitCodes() throws {
        let failure = try #require(GroupActionOutput.failure(mixedReport))
        #expect(failure.code == .groupIncomplete)
        #expect(failure.code.rawValue == 10)
        #expect(failure.message == "Couldn\u{2019}t start 2 virtual machines in \u{201C}Lab\u{201D}.")

        let complete = VMGroupActionReport(
            action: .stop, groupKind: .smartGroup, groupID: UUID(), groupName: "Running",
            results: [
                VMGroupActionResult(vm: summary("Web"), outcome: .done(verb: .stop)),
                VMGroupActionResult(vm: summary("Off", status: "stopped"), outcome: .passedOver(reason: .state)),
                VMGroupActionResult(
                    vm: summary("Busy"),
                    outcome: .passedOver(reason: .refused(error: .busy(vm: summary("Busy"), operation: "suspending")))),
            ])
        #expect(GroupActionOutput.failure(complete) == nil)
        #expect(complete.undone.isEmpty)

        let one = VMGroupActionReport(
            action: .suspend, groupKind: .folder, groupID: UUID(), groupName: "Lab",
            results: [
                VMGroupActionResult(
                    vm: summary("Web"),
                    outcome: .failed(
                        error: .operationFailed(verb: .suspend, title: nil, message: "No.", recovery: nil)))
            ])
        #expect(
            GroupActionOutput.failure(one)?.message
                == "Couldn\u{2019}t suspend 1 virtual machine in \u{201C}Lab\u{201D}.")
    }

    @Test("The report round-trips through the response envelope")
    func reportRoundTrips() throws {
        let response = VMCommandResponse(result: .groupAction(mixedReport))
        let decoded = try JSONDecoder().decode(
            VMCommandResponse.self, from: try JSONEncoder().encode(response))
        #expect(decoded == response)

        let request = VMCommandRequest(verb: .groupAction(.suspend, group: VMGroupReference(.folder, named: "Lab")))
        let decodedRequest = try JSONDecoder().decode(
            VMCommandRequest.self, from: try JSONEncoder().encode(request))
        #expect(decodedRequest == request)
        #expect(decodedRequest.verb.verb == .suspend)
    }
}
