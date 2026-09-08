import CoreServices
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// What a script reads when a verb refuses.
@Suite("Command error as an Apple event error", .admissionGated)
struct CommandErrorAppleEventsTests {
    private func makeSummary(name: String = "Alpha") -> VMSummary {
        VMSummary(id: UUID(), name: name, status: "stopped", ipAddress: .unavailable)
    }

    private func makePrompt(kind: ConfirmationKind = .forceStop) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: kind, title: "Force stop?", message: "Unsaved guest state is lost.",
            confirmTitle: "Force Stop", dismissTitle: "Keep Running")
    }

    @Test("A VM the event could not name is an object that isn't there")
    func addressingFailuresAreNoSuchObject() {
        let vm = makeSummary()
        #expect(
            CommandError.notFound(.name("Alpha")).appleEventErrorNumber == Int(errAENoSuchObject))
        #expect(
            CommandError.ambiguous(selector: .name("Alpha"), candidates: [vm, vm])
                .appleEventErrorNumber == Int(errAENoSuchObject))
    }

    @Test("An ambiguous name reads back with the candidates the core named")
    func ambiguityCarriesItsCandidates() {
        let first = makeSummary(name: "Alpha")
        let second = makeSummary(name: "Alpha")
        let refusal = CommandError.ambiguous(
            selector: .name("Alpha"), candidates: [first, second])

        let message = refusal.appleEventErrorString

        #expect(message == refusal.message)
        #expect(message.contains(first.id.uuidString))
        #expect(message.contains(second.id.uuidString))
    }

    @Test("Everything the verb itself refused is an event that failed")
    func verbRefusalsAreEventFailed() {
        let vm = makeSummary()
        let refusals: [CommandError] = [
            .invalidState(vm: vm, current: .running, allowed: [.stop]),
            .unsupported(capability: "Recovery"),
            .conflict(vm: vm, with: vm, reason: .machineIdentity),
            .confirmationRequired(makePrompt()),
            .busy(vm: vm, operation: "starting"),
            .operationFailed(verb: .stop, message: "The guest did not go down."),
        ]

        for refusal in refusals {
            #expect(refusal.appleEventErrorNumber == Int(errAEEventFailed))
        }
    }

    @Test("A deadline that expired is a timeout")
    func aDeadlineIsATimeout() {
        let refusal = CommandError.timedOut(vm: makeSummary(), verb: .stop, seconds: 30)

        #expect(refusal.appleEventErrorNumber == Int(errAETimeout))
    }

    @Test("An argument the verb cannot use is a type error")
    func aBadArgumentIsATypeError() {
        #expect(
            CommandError.invalidArgument("No such key.").appleEventErrorNumber
                == Int(errAETypeError))
    }

    @Test("A refusal reads back in the words every other door shows")
    func refusalsKeepTheirWords() {
        let refusal = CommandError.operationFailed(verb: .stop, message: "It did not go down.")

        #expect(refusal.appleEventErrorString == refusal.message)
    }

    @Test("A consent refusal names the one thing a script can do about it")
    func consentRefusalsNameTheFlag() {
        let refusal = CommandError.confirmationRequired(makePrompt())

        let message = refusal.appleEventErrorString

        #expect(message.hasPrefix(refusal.message))
        #expect(message.hasSuffix("Add `with confirmation` to do it anyway."))
    }

    @Test("A consent the flag cannot answer promises nothing the flag would do")
    func aRefusalTheFlagCannotAnswerNamesNoFlag() {
        // A paused guest cannot receive the shutdown that raised this, so
        // confirming would substitute a stop nobody asked for — which this
        // surface refuses with the flag as readily as without it.
        let refusal = CommandError.confirmationRequired(makePrompt(kind: .stopPaused))

        #expect(refusal.appleEventErrorString == refusal.message)
    }
}
