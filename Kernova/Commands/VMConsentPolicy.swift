import Foundation
import KernovaKit

/// How a destructive verb's consent is gathered, whichever door asked.
///
/// The decision — which refusals become a question and which stay failures —
/// lives here, apart from the framework call each door asks it with, so it is
/// answerable without an intent session, an alert, or an Apple event.
enum VMConsentPolicy {
    /// Runs a destructive verb, gathering the consent it refuses without.
    ///
    /// `body` is called with `confirmed: false` first; a
    /// ``CommandError/confirmationRequired(_:)`` back from it goes to
    /// `prompting`, and returning from there re-runs `body` with
    /// `confirmed: true`. Every other failure is rethrown untouched — as is a
    /// refusal `prompting` itself declines to answer, which is how a door with
    /// nobody to ask says the consent was never given.
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
    /// of guest state, and the message names both — so the caller is refused and
    /// re-runs with the stop method they meant. Exhaustive rather than
    /// `default`, so a new kind has to choose a side.
    static func isAnsweredByConfirming(_ prompt: ConfirmationPrompt) -> Bool {
        switch prompt.kind {
        case .stopPaused:
            false
        case .forceStop, .deleteVM, .deleteSnapshot, .revertToSnapshot, .cancelPreparing,
            .cancelGuestSetup, .removeAttachment, .enableClipboardPassthrough:
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
