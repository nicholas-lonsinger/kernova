import Cocoa
import CoreServices
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What each script command reads off its event and asks of the gateway.
///
/// Every command is built from the dictionary's own description, the way Cocoa
/// builds it, and its verb is run directly: the event take-over itself needs
/// Cocoa's Apple event handling around it, which only a live script exercises.
@Suite("VM lifecycle script commands", .admissionGated)
@MainActor
struct VMLifecycleScriptCommandsTests {
    private func makeCommand<Command: VMScriptCommand>(
        _ make: (NSScriptCommandDescription) -> Command, code: String,
        arguments: [String: Any] = [:]
    ) throws -> Command {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "Krnv"),
                andAppleEventCode: FourCharCode(scriptingCode: code)))
        let command = make(description)
        command.arguments = arguments
        return command
    }

    private func makeGateway(_ commands: MockVMCommanding) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}), activate: {})
    }

    // MARK: - Reading the event

    @Test("A with/without parameter reads as the flag it was given, and as without when absent")
    func flagsReadTheirParameter() throws {
        let given = try makeCommand(
            VMStartScriptCommand.init(commandDescription:), code: "Strt", arguments: ["RecoveryMode": true])
        let absent = try makeCommand(VMStartScriptCommand.init(commandDescription:), code: "Strt")

        #expect(given.flag("RecoveryMode"))
        #expect(!absent.flag("RecoveryMode"))
    }

    @Test("A deadline parameter reads as seconds, and as no deadline when absent")
    func secondsReadTheirParameter() throws {
        let given = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop", arguments: ["GivingUpAfter": 45])
        let absent = try makeCommand(VMStopScriptCommand.init(commandDescription:), code: "Stop")

        #expect(given.seconds("GivingUpAfter") == 45)
        #expect(absent.seconds("GivingUpAfter") == nil)
    }

    @Test("A refusal records the number and the words the script reads back")
    func refusalsRecordNumberAndMessage() throws {
        let command = try makeCommand(VMPauseScriptCommand.init(commandDescription:), code: "Paus")

        command.refuse(Int(errAEEventFailed), "Kernova is not ready to answer scripts.")

        #expect(command.scriptErrorNumber == Int(errAEEventFailed))
        #expect(command.scriptErrorString == "Kernova is not ready to answer scripts.")
    }

    @Test("The core's refusal is recorded as the Apple event error it maps to")
    func aCoreRefusalRecordsItsMapping() throws {
        let command = try makeCommand(VMPauseScriptCommand.init(commandDescription:), code: "Paus")
        let refusal = CommandError.notFound(.name("Alpha"))

        command.refuse(refusal)

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == refusal.message)
    }

    // MARK: - Running the verb

    @Test("start passes recovery mode through")
    func startPassesRecoveryMode() async throws {
        let commands = MockVMCommanding()
        let command = try makeCommand(
            VMStartScriptCommand.init(commandDescription:), code: "Strt", arguments: ["RecoveryMode": true])

        try await command.run(makeGateway(commands), on: [.name("Alpha")])

        #expect(commands.startCalls.map(\.selector) == [.name("Alpha")])
        #expect(commands.startCalls.map(\.recovery) == [true])
    }

    @Test("stop passes the method, the consent, and the deadline through")
    func stopPassesItsParameters() async throws {
        let commands = MockVMCommanding()
        commands.stopConsentPrompt = ConfirmationPrompt(
            kind: .forceStop, title: "Force stop?", message: "Unsaved guest state is lost.",
            confirmTitle: "Force Stop", dismissTitle: "Keep Running")
        let command = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop",
            arguments: [
                "StopMethod": NSNumber(value: VMScriptStopMethod.force.code),
                "Confirmation": true, "GivingUpAfter": 30,
            ])

        try await command.run(makeGateway(commands), on: [.name("Alpha")])

        // The consent is what answers the prompt the core describes, so the
        // verb is issued once to ask and once more, consented.
        #expect(commands.stopCalls.map(\.disposition) == [.force, .force])
        #expect(commands.stopCalls.map(\.confirmed) == [false, true])
        #expect(commands.stopCalls.map(\.timeout) == [30, 30])
    }

    @Test("stop shuts down when no method is named")
    func stopShutsDownByDefault() async throws {
        let commands = MockVMCommanding()
        let command = try makeCommand(VMStopScriptCommand.init(commandDescription:), code: "Stop")

        try await command.run(makeGateway(commands), on: [.name("Alpha")])

        #expect(commands.stopCalls.map(\.disposition) == [.graceful])
        #expect(commands.stopCalls.map(\.confirmed) == [false])
        #expect(commands.stopCalls.map(\.timeout) == [nil])
    }

    @Test("A stop method from no vocabulary this app writes is a type error, and stops nothing")
    func anUnknownStopMethodIsRefused() async throws {
        let commands = MockVMCommanding()
        let command = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop",
            arguments: ["StopMethod": NSNumber(value: FourCharCode(scriptingCode: "KmXX"))])

        let refusal = await #expect(throws: CommandError.self) {
            try await command.run(makeGateway(commands), on: [.name("Alpha")])
        }

        #expect(refusal?.appleEventErrorNumber == Int(errAETypeError))
        #expect(commands.stopCalls.isEmpty)
    }

    @Test("restart passes the deadline through")
    func restartPassesItsDeadline() async throws {
        let commands = MockVMCommanding()
        let command = try makeCommand(
            VMRestartScriptCommand.init(commandDescription:), code: "Rstr", arguments: ["GivingUpAfter": 20])

        try await command.run(makeGateway(commands), on: [.name("Alpha")])

        #expect(commands.restartCalls.map(\.timeout) == [20])
    }

    @Test("pause, resume, suspend and reveal each reach their verb")
    func plainVerbsReachTheCore() async throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        let alpha = VMSelector.name("Alpha")

        try await makeCommand(VMPauseScriptCommand.init(commandDescription:), code: "Paus").run(gateway, on: [alpha])
        try await makeCommand(VMResumeScriptCommand.init(commandDescription:), code: "Resu").run(gateway, on: [alpha])
        try await makeCommand(VMSuspendScriptCommand.init(commandDescription:), code: "Susp").run(gateway, on: [alpha])
        try await makeCommand(VMRevealScriptCommand.init(commandDescription:), code: "Revl").run(gateway, on: [alpha])

        #expect(commands.pauseSelectors == [alpha])
        #expect(commands.resumeCalls.map(\.selector) == [alpha])
        #expect(commands.suspendSelectors == [alpha])
        #expect(commands.revealSelectors == [alpha])
    }
}
