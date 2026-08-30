import AppIntents
import Foundation
import KernovaKit

/// How a destructive verb's consent is gathered on this surface.
///
/// The decision — which refusals become a question and which stay failures —
/// lives here, apart from the framework call that asks it, so it is answerable
/// without an intent session.
enum VMIntentConsent {
    /// Runs a destructive verb, gathering the consent it refuses without.
    ///
    /// `body` is called with `confirmed: false` first; a
    /// ``CommandError/confirmationRequired(_:)`` back from it goes to
    /// `prompting`, and returning from there re-runs `body` with
    /// `confirmed: true`. Every other failure is rethrown untouched.
    ///
    /// A prompt offering ``ConfirmationPrompt/alternatives`` is rethrown rather
    /// than asked: those are not a yes/no question — a paused guest's stop
    /// offers "resume then shut down" *and* "force", which discard different
    /// amounts of guest state — so the message names them and the user re-runs
    /// the intent with the disposition they meant.
    @MainActor
    static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        _ body: (_ confirmed: Bool) async throws -> Void
    ) async throws {
        do {
            try await body(false)
        } catch let error as CommandError {
            guard let prompt = error.confirmationPrompt, prompt.alternatives.isEmpty else {
                throw error
            }
            try await prompting(prompt)
            try await body(true)
        }
    }
}

extension AppIntent {
    /// Runs a destructive verb, raising the framework's own confirmation for the
    /// consent it refuses without (``VMIntentConsent/run(prompting:_:)``).
    @MainActor
    func runWithConsent(_ body: (_ confirmed: Bool) async throws -> Void) async throws {
        try await VMIntentConsent.run(
            prompting: { prompt in
                try await requestConfirmation(
                    actionName: .custom(
                        acceptLabel: "\(prompt.confirmTitle)",
                        acceptAlternatives: [],
                        denyLabel: "\(prompt.dismissTitle)",
                        denyAlternatives: [],
                        destructive: true),
                    dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
            },
            body)
    }
}
