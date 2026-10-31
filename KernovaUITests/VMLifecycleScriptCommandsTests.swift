import Cocoa
import CoreServices
import Foundation
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

    @Test("stop passes the method and the consent through")
    func stopPassesItsParameters() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let command = try makeCommand(
            VMStopScriptCommand.init(commandDescription:), code: "Stop",
            arguments: [
                "StopMethod": NSNumber(value: VMScriptStopMethod.force.code),
                "Confirmation": true, "GivingUpAfter": 30,
            ])

        // The force stop refuses without consent, so the termination is the
        // consent's doing.
        try await command.run(makeGateway(wired), on: [.name("Alpha")])

        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 0)
        #expect(alpha.status == .stopped)
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

    @Test("stop shuts down when no method is named")
    func stopShutsDownByDefault() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let command = try makeCommand(VMStopScriptCommand.init(commandDescription:), code: "Stop")

        try await command.run(makeGateway(wired), on: [.name("Alpha")])

        #expect(virtualization.stopCallCount == 1)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(alpha.status == .stopped)
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

    @Test("suspend with confirmation unplugs a USB disk that may lose changes; without, it asks")
    func suspendPassesItsConfirmation() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let sessionID = UUID()
        let item = RemovableMediaItem(path: "/Volumes/Media/backup.img", readOnly: false)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [item]
        }
        alpha.beginSessionContextForTesting()
        alpha.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: item.id, path: item.path, readOnly: false), for: sessionID)
        let unconfirmed = try makeCommand(VMSuspendScriptCommand.init(commandDescription:), code: "Susp")
        let confirmed = try makeCommand(
            VMSuspendScriptCommand.init(commandDescription:), code: "Susp",
            arguments: ["Confirmation": true])

        let refusal = try await #require(throws: CommandError.self) {
            try await unconfirmed.run(makeGateway(wired), on: [.name("Alpha")])
        }
        #expect(refusal.confirmationPrompt?.kind == .unplugUSBDisksAtRisk)
        #expect(virtualization.saveCallCount == 0)

        try await confirmed.run(makeGateway(wired), on: [.name("Alpha")])

        #expect(virtualization.saveCallCount == 1)
        #expect(alpha.status == .suspended)
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
