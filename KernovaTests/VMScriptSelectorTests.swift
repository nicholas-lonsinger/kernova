import Cocoa
import CoreServices
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// How an Apple event's addressing becomes the core's ``VMSelector``.
///
/// The specifiers are the ones Cocoa builds for each form a script can write,
/// evaluated where evaluation is what reads them — against the test host,
/// whose `virtual machines` element is empty.
@Suite("VM script selector", .admissionGated)
@MainActor
struct VMScriptSelectorTests {
    private func makeContainer() throws -> NSScriptClassDescription {
        try #require(NSScriptClassDescription(for: NSApplication.self))
    }

    private func evaluationFailure(
        _ body: () throws -> [VMSelector]
    ) -> VMScriptEvaluationFailure? {
        do {
            _ = try body()
            return nil
        } catch let failure as VMScriptEvaluationFailure {
            return failure
        } catch {
            return nil
        }
    }

    /// One of the app's own verbs, as the command a failure is recorded on.
    private func makeCommand() throws -> VMScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "Krnv"),
                andAppleEventCode: FourCharCode(scriptingCode: "Paus")))
        return VMScriptCommand(commandDescription: description)
    }

    /// The object `failure` names at fault, recorded for what `addressed`
    /// addressed.
    private func offendingObject(
        of failure: VMScriptEvaluationFailure, addressing addressed: Any
    ) throws -> NSAppleEventDescriptor? {
        let command = try makeCommand()
        failure.record(on: command, addressing: addressed)
        return command.scriptErrorOffendingObjectDescriptor
    }

    @Test("A name of the application's element reaches the core as a name")
    func aNameSpecifierIsReadAsAName() throws {
        let specifier = NSNameSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, name: "Alpha")

        // The core is what refuses a name several VMs answer to, with the
        // candidates listed; evaluating here would lose that.
        #expect(try VMScriptSelector.selectors(addressing: specifier) == [.name("Alpha")])
    }

    @Test("An identifier of the application's element reaches the core as an identifier")
    func aUniqueIDSpecifierIsReadAsAnIdentifier() throws {
        let id = UUID()
        let specifier = NSUniqueIDSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, uniqueID: id.uuidString)

        #expect(try VMScriptSelector.selectors(addressing: specifier) == [.id(id)])
    }

    @Test("An identifier Kernova never issued is left to the evaluation, which refuses it")
    func anUnparsableIdentifierIsEvaluated() throws {
        let specifier = NSUniqueIDSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, uniqueID: "not-a-uuid")

        let failure = try #require(
            evaluationFailure { try VMScriptSelector.selectors(addressing: specifier) })
        #expect(failure.number == Int(errAENoSuchObject))
        #expect(try offendingObject(of: failure, addressing: specifier) != nil)
    }

    @Test("A name under another container is not read as a name of the library")
    func aNameUnderAContainerIsEvaluated() throws {
        // `virtual machine "Alpha" of window 999999`: read as a name it would
        // reach the core; evaluated, the window is what fails.
        let window = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: "orderedWindows", index: 999_999)
        let specifier = NSNameSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: window,
            key: AppDelegate.virtualMachinesKey, name: "Alpha")

        let failure = try #require(
            evaluationFailure { try VMScriptSelector.selectors(addressing: specifier) })
        #expect(try offendingObject(of: failure, addressing: specifier) != nil)
    }

    @Test("Every virtual machine of an empty library addresses nothing and refuses nothing")
    func everyElementOfAnEmptyLibraryIsEmpty() throws {
        let specifier = NSPropertySpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey)

        #expect(try VMScriptSelector.selectors(addressing: specifier).isEmpty)
    }

    @Test("A position the library has no VM at is refused, naming the position")
    func anIndexPastTheLibraryIsRefused() throws {
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, index: 0)

        let failure = try #require(
            evaluationFailure { try VMScriptSelector.selectors(addressing: specifier) })
        #expect(try offendingObject(of: failure, addressing: specifier) != nil)
    }

    @Test("An evaluation's failure reads as the number Cocoa's own evaluation reports")
    func failuresMapToCocoasNumbers() throws {
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, index: 0)

        specifier.evaluationErrorNumber = NSInvalidIndexSpecifierError
        #expect(VMScriptEvaluationFailure(specifier).number == Int(errAEIllegalIndex))

        for code in [
            NSInternalSpecifierError, NSUnknownKeySpecifierError, NSContainerSpecifierError,
        ] {
            specifier.evaluationErrorNumber = code
            #expect(VMScriptEvaluationFailure(specifier).number == Int(errAENoSuchObject))
        }
    }

    @Test("A list of specifiers addresses the VMs each names, in order")
    func aListAddressesEachSpecifier() throws {
        let id = UUID()
        let list: [Any] = [
            NSNameSpecifier(
                containerClassDescription: try makeContainer(), containerSpecifier: nil,
                key: AppDelegate.virtualMachinesKey, name: "Alpha"),
            NSUniqueIDSpecifier(
                containerClassDescription: try makeContainer(), containerSpecifier: nil,
                key: AppDelegate.virtualMachinesKey, uniqueID: id.uuidString),
        ]

        #expect(try VMScriptSelector.selectors(addressing: list) == [.name("Alpha"), .id(id)])
        #expect(try VMScriptSelector.selectors(addressing: [Any]()).isEmpty)
    }

    @Test("A list item that is not a specifier is a type error naming the item")
    func aNonSpecifierListItemIsRefused() throws {
        let list: [Any] = [
            NSNameSpecifier(
                containerClassDescription: try makeContainer(), containerSpecifier: nil,
                key: AppDelegate.virtualMachinesKey, name: "Alpha"),
            3,
        ]

        let refusal = #expect(throws: CommandError.self) {
            try VMScriptSelector.selectors(addressing: list)
        }

        #expect(refusal?.appleEventErrorNumber == Int(errAETypeError))
        #expect(refusal?.message.contains("item 2") == true)
    }

    @Test("A failure records its number and the specifier at fault on the command")
    func aFailureRecordsItselfOnTheCommand() throws {
        let command = try makeCommand()
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, index: 9)
        // A failure is recorded only after an evaluation, which the empty
        // library has no ninth VM for.
        #expect(specifier.objectsByEvaluatingSpecifier == nil)

        VMScriptEvaluationFailure(number: Int(errAEIllegalIndex))
            .record(on: command, addressing: specifier)

        #expect(command.scriptErrorNumber == Int(errAEIllegalIndex))
        #expect(command.scriptErrorOffendingObjectDescriptor != nil)
    }

    @Test("A failure addressing a list names the item at fault, and nothing when none is")
    func aFailureInAListNamesTheItemAtFault() throws {
        let named = NSNameSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, name: "Alpha")
        let indexed = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, index: 9)
        // The name reaches the core unevaluated, so the position is the only
        // item the empty library fails, as it is for a script.
        let failure = try #require(
            evaluationFailure {
                try VMScriptSelector.selectors(addressing: [named, indexed] as [Any])
            })

        #expect(try offendingObject(of: failure, addressing: [named, indexed] as [Any]) != nil)
        #expect(try offendingObject(of: failure, addressing: [named] as [Any]) == nil)
    }
}
