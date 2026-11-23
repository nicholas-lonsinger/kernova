import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// How an Apple event's addressing becomes the core's ``VMSelector``.
///
/// The specifiers are the ones Cocoa builds for each form a script can write,
/// evaluated where evaluation is what reads them — against the test host,
/// whose `virtual machines` element is empty.
@Suite("VM script selector", .caseScoped)
@MainActor
struct VMScriptSelectorTests {
    private func makeContainer() throws -> NSScriptClassDescription {
        try #require(NSScriptClassDescription(for: NSApplication.self))
    }

    /// One of the app's own verbs, as the command a failure is recorded on.
    private func makeCommand() throws -> VMScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "Krnv"),
                andAppleEventCode: FourCharCode(scriptingCode: "Paus")))
        return VMScriptCommand(commandDescription: description)
    }

    @Test("An evaluation's failure reads as the number Cocoa's own evaluation reports")
    func failuresMapToCocoasNumbers() throws {
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: VMScriptingRoot.virtualMachinesKey, index: 0)

        specifier.evaluationErrorNumber = NSInvalidIndexSpecifierError
        #expect(VMScriptEvaluationFailure(specifier).number == Int(errAEIllegalIndex))

        for code in [
            NSInternalSpecifierError, NSUnknownKeySpecifierError, NSContainerSpecifierError,
        ] {
            specifier.evaluationErrorNumber = code
            #expect(VMScriptEvaluationFailure(specifier).number == Int(errAENoSuchObject))
        }
    }

    @Test("A failure records its number and the specifier at fault on the command")
    func aFailureRecordsItselfOnTheCommand() throws {
        let command = try makeCommand()
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: VMScriptingRoot.virtualMachinesKey, index: 9)
        // A failure is recorded only after an evaluation, which the empty
        // library has no ninth VM for.
        #expect(specifier.objectsByEvaluatingSpecifier == nil)

        VMScriptEvaluationFailure(number: Int(errAEIllegalIndex))
            .record(on: command, addressing: specifier)

        #expect(command.scriptErrorNumber == Int(errAEIllegalIndex))
        #expect(command.scriptErrorOffendingObjectDescriptor != nil)
    }
}
