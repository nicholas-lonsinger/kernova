import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

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
}
