import Cocoa
import CoreServices
import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// What each script command reads off its event and asks of the gateway.
///
/// Every command is built from the dictionary's own description, the way Cocoa
/// builds it, and its verb is run directly: the event take-over itself needs
/// Cocoa's Apple event handling around it, which only a live script exercises.
@Suite("VM lifecycle script commands", .caseScoped)
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

    private func makeGateway(_ wired: WiredCommandCore) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            prepareToSurface: {})
    }

    // MARK: - Running the verb

    @Test("start passes recovery mode through")
    func startPassesRecoveryMode() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", guestOS: .macOS)
        let command = try makeCommand(
            VMStartScriptCommand.init(commandDescription:), code: "Strt", arguments: ["RecoveryMode": true])

        try await command.run(makeGateway(wired), on: [.name("Alpha")])

        #expect(virtualization.startCallCount == 1)
        #expect(virtualization.lastStartBootIntoRecovery)
        #expect(alpha.status == .running)
    }

    @Test(
        "stop method anyway asks for its consent where offered, and is refused naming the For everyone install where not"
    )
    func stopStopAnywayRoutes() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()), guestOS: .macOS)
        func command(confirmation: Bool) throws -> VMStopScriptCommand {
            try makeCommand(
                VMStopScriptCommand.init(commandDescription:), code: "Stop",
                arguments: [
                    "StopMethod": NSNumber(value: VMScriptStopMethod.anyway.code),
                    "Confirmation": confirmation,
                ])
        }

        let unoffered = try await #require(throws: CommandError.self) {
            try await command(confirmation: true).run(makeGateway(wired), on: [.name("Alpha")])
        }
        #expect(unoffered.stepRequirement?.message.contains("\u{201C}For everyone\u{201D}") == true)

        alpha.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]), powerIgnoringApps: .agent(.systemPeer)))
        let unconsented = try await #require(throws: CommandError.self) {
            try await command(confirmation: false).run(makeGateway(wired), on: [.name("Alpha")])
        }
        #expect(unconsented.confirmationPrompt?.kind == .stopAnyway)

        #expect(virtualization.stopCallCount == 0)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(alpha.status == .running)
    }

    @Test("stop's deadline bounds the wait for the power-off")
    func stopPassesItsDeadline() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let wired = WiredCommandCore(virtualization: virtualization, clock: TestEngineClock())
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let command = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop", arguments: ["GivingUpAfter": 30])

        let refusal = try await #require(throws: CommandError.self) {
            try await command.run(makeGateway(wired), on: [.name("Alpha")])
        }

        #expect(refusal == .timedOut(vm: wired.core.summary(alpha), verb: .stop, seconds: 30))
        #expect(alpha.status == .running)
    }

    @Test("A stop method from no vocabulary this app writes is a type error, and stops nothing")
    func anUnknownStopMethodIsRefused() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let command = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop",
            arguments: ["StopMethod": NSNumber(value: FourCharCode(scriptingCode: "KmXX"))])

        let refusal = await #expect(throws: CommandError.self) {
            try await command.run(makeGateway(wired), on: [.name("Alpha")])
        }

        #expect(refusal?.appleEventErrorNumber == Int(errAETypeError))
        #expect(virtualization.stopCallCount == 0)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(alpha.status == .running)
    }

    @Test("restart passes the deadline through")
    func restartPassesItsDeadline() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let wired = WiredCommandCore(virtualization: virtualization, clock: TestEngineClock())
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let command = try makeCommand(
            VMRestartScriptCommand.init(commandDescription:), code: "Rstr", arguments: ["GivingUpAfter": 20])

        let refusal = try await #require(throws: CommandError.self) {
            try await command.run(makeGateway(wired), on: [.name("Alpha")])
        }

        #expect(refusal == .timedOut(vm: wired.core.summary(alpha), verb: .restart, seconds: 20))
        #expect(alpha.status == .running)
    }

    @Test("restart with confirmation answers the consent it asks for")
    func restartPassesItsConfirmation() async throws {
        let virtualization = MockVirtualizationService()
        let preferences = makeTestPreferences()
        preferences.allowsDuplicateMachineIDOverride = true
        let wired = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let identity = Data([4, 4, 4])
        wired.register(name: "Twin", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID())) {
            $0.genericMachineIdentifierData = identity
        }
        let unconfirmed = try makeCommand(VMRestartScriptCommand.init(commandDescription:), code: "Rstr")
        let confirmed = try makeCommand(
            VMRestartScriptCommand.init(commandDescription:), code: "Rstr",
            arguments: ["Confirmation": true])

        let refusal = try await #require(throws: CommandError.self) {
            try await unconfirmed.run(makeGateway(wired), on: [.name("Alpha")])
        }
        #expect(refusal.confirmationPrompt?.kind == .startBesideSharedMachineIdentity)
        #expect(virtualization.stopCallCount == 0)

        try await confirmed.run(makeGateway(wired), on: [.name("Alpha")])

        #expect(virtualization.stopCallCount == 1)
        #expect(virtualization.startCallCount == 1)
        #expect(alpha.status == .running)
    }

    @Test("pause, resume, suspend and reveal each reach their verb")
    func plainVerbsReachTheCore() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let gateway = makeGateway(wired)
        let selector = VMSelector.name("Alpha")

        try await makeCommand(VMPauseScriptCommand.init(commandDescription:), code: "Paus").run(gateway, on: [selector])
        #expect(alpha.status == .paused)
        try await makeCommand(VMResumeScriptCommand.init(commandDescription:), code: "Resu").run(
            gateway, on: [selector])
        #expect(alpha.status == .running)
        try await makeCommand(VMSuspendScriptCommand.init(commandDescription:), code: "Susp").run(
            gateway, on: [selector])
        #expect(alpha.status == .suspended)
        try await makeCommand(VMRevealScriptCommand.init(commandDescription:), code: "Revl").run(
            gateway, on: [selector])

        #expect(virtualization.pauseCallCount == 1)
        #expect(virtualization.resumeCallCount == 1)
        #expect(virtualization.saveCallCount == 1)
        #expect(wired.surfacedDisplays == [alpha.id])
    }
}
