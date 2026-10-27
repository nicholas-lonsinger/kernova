import Foundation
import KernovaCommandModel

/// How what a verb refuses without is gathered, whichever door asked.
///
/// The decision — which refusals become a question and which stay failures —
/// lives here, apart from the framework call each door asks it with, so it is
/// answerable without an intent session, an alert, or an Apple event.
///
/// Two loops, one shape: run the verb, turn the refusal it names into the
/// question that door can ask, run it again. They differ in where the answer
/// lands. A consent is given for the verb the user was shown, so it rides the
/// re-issued call and a call that never ran leaves nothing behind; an account
/// answer is about the VM, so the door supplies it with the verb that holds it
/// and the re-issued call simply finds it there.
package enum VMConsentPolicy {
    /// Runs a verb, gathering each consent it refuses without.
    ///
    /// `body` is called with ``Consent/none`` first; a
    /// ``CommandError/confirmationRequired(_:)`` back from it goes to
    /// `prompting`, and returning from there re-runs `body` with that prompt's
    /// kind added — so a verb that needs two consents asks each with its own
    /// words. Every other failure is rethrown untouched — as is a refusal
    /// `prompting` itself declines to answer, which is how a door with nobody
    /// to ask says the consent was never given, and a refusal for a kind
    /// already given, which is the answer not having taken.
    @MainActor
    package static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        _ body: (Consent) async throws -> Void
    ) async throws {
        try await run(
            prompting: prompting,
            choosingRoute: { throw CommandError.stepRequired($0) },
            taking: { _ in }
        ) { consent, _ in try await body(consent) }
    }

    /// ``run(prompting:_:)`` for a door that chains steps — the app's own
    /// view model: a ``CommandError/stepRequired(_:)`` naming routes goes to
    /// `choosingRoute`, each step of the route it answers goes to `taking` in
    /// order, and `body` then runs again with every consent given so far and
    /// the route's ``StepRoute/ending`` — ``StepRoute/Ending/refusedVerb``
    /// until a route is taken — which names the request it asks.
    ///
    /// One loop rather than two nested ones, because a confirmation can be
    /// asked before the step refusal is reached — a shared machine identity
    /// is answered before a MAC address — and each re-run has to carry the
    /// consents. One route per run: a second
    /// step refusal is the route not having taken, and is rethrown, as is a
    /// step refusal naming no route. What `choosingRoute` or `taking` throws
    /// ends the run: how a door says nobody chose, and a step that failed.
    @MainActor
    static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        choosingRoute: (StepRequirement) async throws -> StepRoute,
        taking: (CommandStep) async throws -> Void,
        _ body: (Consent, StepRoute.Ending) async throws -> Void
    ) async throws {
        var consent = Consent.none
        var ending: StepRoute.Ending?
        while true {
            do {
                try await body(consent, ending ?? .refusedVerb)
                return
            } catch let error as CommandError {
                if let prompt = error.confirmationPrompt, !consent.covers(prompt.kind) {
                    try await prompting(prompt)
                    consent = consent.adding(prompt.kind)
                } else if let requirement = error.stepRequirement, ending == nil,
                    !requirement.routes.isEmpty
                {
                    let route = try await choosingRoute(requirement)
                    ending = route.ending
                    for step in route.steps { try await taking(step) }
                } else {
                    throw error
                }
            }
        }
    }

    /// Runs a start, gathering the guest account it refuses without.
    ///
    /// A ``CommandError/guestAccountPasswordRequired(_:)`` out of `body` goes to
    /// `prompting`, which both asks and supplies the answer — through
    /// ``VMCommandCore/provideGuestAccountPassword(_:password:)`` or
    /// ``VMCommandCore/skipGuestAccount(_:)`` — and `body` is then run again,
    /// finding the VM answered for. Every other failure is rethrown untouched —
    /// as is whatever `prompting` throws, which is how a door with nobody to ask,
    /// and a user who walked away from the question, both say the start is not
    /// happening.
    ///
    /// Exactly one re-run. The second refusal is the answer not having taken,
    /// which is a failure to report rather than a question to ask twice.
    @MainActor
    static func runGatheringGuestAccount(
        prompting: (GuestAccountPrompt) async throws -> Void,
        _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch let error as CommandError {
            guard let prompt = error.guestAccountPrompt else { throw error }
            try await prompting(prompt)
            try await body()
        }
    }
}
