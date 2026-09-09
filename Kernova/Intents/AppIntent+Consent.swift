import AppIntents
import Foundation
import KernovaKit

extension AppIntent {
    /// Runs a destructive verb, raising the framework's own confirmation for the
    /// consent it refuses without (``VMConsentPolicy/run(prompting:_:)``).
    ///
    /// `asking` turns the refusal into the confirm action's label and whether
    /// taking it destroys anything; by default both are the ones the core named.
    /// A verb whose parameters already chose among the prompt's routes passes
    /// its choice — and refuses from there, rather than confirming, when the
    /// prompt shows the choice cannot be honoured.
    @MainActor
    func runWithConsent(
        asking: (ConfirmationPrompt) throws -> (title: String, isDestructive: Bool) = {
            ($0.confirmTitle, $0.confirmIsDestructive)
        },
        _ body: (_ confirmed: Bool) async throws -> Void
    ) async throws {
        try await VMConsentPolicy.run(
            prompting: { prompt in
                let accept = try asking(prompt)
                try await requestConfirmation(
                    actionName: .custom(
                        acceptLabel: "\(accept.title)",
                        acceptAlternatives: [],
                        denyLabel: "\(prompt.dismissTitle)",
                        denyAlternatives: [],
                        destructive: accept.isDestructive),
                    dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
            },
            body)
    }
}
