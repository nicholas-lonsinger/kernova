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
    /// A prompt confirming to something other than what was asked for is
    /// rethrown instead (``isAnsweredByConfirming(_:)``).
    @MainActor
    static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        _ body: (_ confirmed: Bool) async throws -> Void
    ) async throws {
        do {
            try await body(false)
        } catch let error as CommandError {
            guard let prompt = error.confirmationPrompt, isAnsweredByConfirming(prompt) else {
                throw error
            }
            try await prompting(prompt)
            try await body(true)
        }
    }

    /// Whether confirming `prompt` performs the verb that was asked for.
    ///
    /// The presence of alternatives does not decide this: a force stop's "Shut
    /// Down" alternative is the gentler route the caller declined by asking for
    /// a force stop, and confirming still force-stops exactly as asked.
    ///
    /// ``ConfirmationKind/stopPaused`` is the one that cannot. A paused guest
    /// cannot receive the graceful shutdown that raised it, so confirming
    /// substitutes a resume-then-shut-down and its alternative substitutes a
    /// force stop. Neither is what was asked for, they discard different amounts
    /// of guest state, and the message names both — so this surface refuses and
    /// the user re-runs with the stop method they meant. Exhaustive rather than
    /// `default`, so a new kind has to choose a side.
    static func isAnsweredByConfirming(_ prompt: ConfirmationPrompt) -> Bool {
        switch prompt.kind {
        case .stopPaused:
            false
        case .forceStop, .deleteVM, .deleteSnapshot, .revertToSnapshot, .cancelPreparing,
            .cancelGuestSetup, .removeAttachment:
            true
        }
    }

    /// The action that performs a revert with `takingCheckpoint`, `nil` when
    /// the VM cannot take one and so cannot perform that revert at all.
    ///
    /// The core names both routes — its own confirm action reverts, and a
    /// `takesCheckpoint` alternative captures first — and offers the
    /// alternative only where a capture can be taken. A surface that has
    /// already chosen between them shows the chosen one's words rather than
    /// inventing copy, and learns from the missing alternative that the choice
    /// cannot be honoured.
    static func revertAction(_ prompt: ConfirmationPrompt, takingCheckpoint: Bool) -> String? {
        guard takingCheckpoint else { return prompt.confirmTitle }
        return prompt.alternatives.first { $0.takesCheckpoint }?.title
    }
}

extension AppIntent {
    /// Runs a destructive verb, raising the framework's own confirmation for the
    /// consent it refuses without (``VMIntentConsent/run(prompting:_:)``).
    ///
    /// `asking` turns the refusal into the confirm action's label; by default
    /// that is the one the core named. A verb whose parameters already chose
    /// among the prompt's routes passes the label for its choice — and refuses
    /// from there, rather than confirming, when the prompt shows the choice
    /// cannot be honoured.
    @MainActor
    func runWithConsent(
        asking: (ConfirmationPrompt) throws -> String = { $0.confirmTitle },
        _ body: (_ confirmed: Bool) async throws -> Void
    ) async throws {
        try await VMIntentConsent.run(
            prompting: { prompt in
                let accept = try asking(prompt)
                try await requestConfirmation(
                    actionName: .custom(
                        acceptLabel: "\(accept)",
                        acceptAlternatives: [],
                        denyLabel: "\(prompt.dismissTitle)",
                        denyAlternatives: [],
                        destructive: true),
                    dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
            },
            body)
    }
}
