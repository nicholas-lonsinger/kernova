import Foundation
import KernovaKit
import Testing

@testable import Kernova

@Suite("VMConsentPolicy Tests", .caseScoped)
@MainActor
struct VMConsentPolicyTests {
    private func prompt(_ kind: ConfirmationKind) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: kind, title: "\(kind)?", message: "What \(kind) does.", confirmTitle: "Go",
            dismissTitle: "Cancel")
    }

    /// A verb refusing each of `needs` in turn until its consent covers it.
    private func verb(needing needs: [ConfirmationKind]) -> (Consent) throws -> Void {
        { consent in
            if let missing = needs.first(where: { !consent.covers($0) }) {
                throw CommandError.confirmationRequired(prompt(missing))
            }
        }
    }

    @Test("A verb needing two consents asks each with its own prompt, then runs with both")
    func asksEachConsentInTurn() async throws {
        var asked: [ConfirmationKind] = []
        var given: [Consent] = []
        let needs: [ConfirmationKind] = [.revertToSnapshot, .startBesideSharedMachineIdentity]

        try await VMConsentPolicy.run(prompting: { asked.append($0.kind) }) { consent in
            given.append(consent)
            try verb(needing: needs)(consent)
        }

        #expect(asked == needs)
        #expect(
            given == [
                .none, Consent([.revertToSnapshot]),
                Consent([.revertToSnapshot, .startBesideSharedMachineIdentity]),
            ])
    }

    @Test("A refusal for a consent already given is rethrown rather than asked again")
    func aRepeatedRefusalIsRethrown() async throws {
        var asked = 0
        let refusal = CommandError.confirmationRequired(prompt(.forceStop))

        await #expect(throws: refusal) {
            try await VMConsentPolicy.run(prompting: { _ in asked += 1 }) { _ in throw refusal }
        }
        #expect(asked == 1)
    }

    @Test("A declined prompt ends the loop with what the prompt threw")
    func aDeclinedPromptEndsTheLoop() async throws {
        struct Declined: Error {}
        var runs = 0

        await #expect(throws: Declined.self) {
            try await VMConsentPolicy.run(prompting: { _ in throw Declined() }) { consent in
                runs += 1
                try verb(needing: [.startBesideSharedMachineIdentity])(consent)
            }
        }
        #expect(runs == 1)
    }

    // MARK: - Step routes

    private let vm = VMSummary(
        id: UUID(), name: "Clone", status: "stopped", ipAddress: .unavailable,
        heldByAnotherCopy: false)

    private func requirement(routes: Int = 2) -> StepRequirement {
        StepRequirement(
            title: "Duplicate MAC Address", message: "Change its network first.",
            routes: (0..<routes).map { index in
                StepRoute(
                    title: "Route \(index)",
                    steps: [
                        .discardSavedState(vm: vm),
                        .setConfiguration(
                            vm: vm, assignments: [ConfigurationEntry(key: "k\(index)", value: "v")]),
                    ], ending: .refusedVerb)
            })
    }

    @Test("A route chosen has its steps taken in order, then the verb runs again with the consents given")
    func routeStepsRunBeforeTheVerbAgain() async throws {
        let refused = requirement()
        var taken: [CommandStep] = []
        var given: [Consent] = []

        try await VMConsentPolicy.run(
            prompting: { _ in },
            choosingRoute: { $0.routes[1] },
            taking: { taken.append($0) }
        ) { consent, _ in
            given.append(consent)
            guard !taken.isEmpty else { throw CommandError.stepRequired(refused) }
            try verb(needing: [.startBesideSharedMachineIdentity])(consent)
        }

        #expect(taken == refused.routes[1].steps)
        #expect(given == [.none, .none, Consent([.startBesideSharedMachineIdentity])])
    }

    @Test("A route ending in a start is answered by the start, not the refused verb")
    func routeEndingInAStartRunsTheStart() async throws {
        let refused = StepRequirement(
            message: "M",
            routes: [StepRoute(title: "New", steps: [.discardSavedState(vm: vm)], ending: .start(vm: vm))])
        var endings: [StepRoute.Ending] = []

        try await VMConsentPolicy.run(
            prompting: { _ in }, choosingRoute: { $0.routes[0] }, taking: { _ in }
        ) { _, ending in
            endings.append(ending)
            guard endings.count > 1 else { throw CommandError.stepRequired(refused) }
        }

        #expect(endings == [.refusedVerb, .start(vm: vm)])
    }

    @Test("A second step refusal after a route is rethrown rather than asked again")
    func aRepeatedStepRefusalIsRethrown() async throws {
        var asked = 0
        let refusal = CommandError.stepRequired(requirement())

        await #expect(throws: refusal) {
            try await VMConsentPolicy.run(
                prompting: { _ in },
                choosingRoute: {
                    asked += 1
                    return $0.routes[0]
                },
                taking: { _ in }
            ) { _, _ in throw refusal }
        }
        #expect(asked == 1)
    }

    @Test("A step that fails ends the run before the verb runs again")
    func aFailedStepEndsTheRun() async throws {
        struct StepFailed: Error {}
        var runs = 0

        await #expect(throws: StepFailed.self) {
            try await VMConsentPolicy.run(
                prompting: { _ in },
                choosingRoute: { $0.routes[0] },
                taking: { _ in throw StepFailed() }
            ) { _, _ in
                runs += 1
                throw CommandError.stepRequired(requirement())
            }
        }
        #expect(runs == 1)
    }

    @Test("A step refusal naming no route, or met by a door that cannot chain steps, stands")
    func unroutableStepRefusalStands() async throws {
        let empty = CommandError.stepRequired(requirement(routes: 0))
        await #expect(throws: empty) {
            try await VMConsentPolicy.run(
                prompting: { _ in }, choosingRoute: { $0.routes[0] }, taking: { _ in }
            ) { _, _ in throw empty }
        }

        let routed = CommandError.stepRequired(requirement())
        await #expect(throws: routed) {
            try await VMConsentPolicy.run(prompting: { _ in }) { _ in throw routed }
        }
    }
}
