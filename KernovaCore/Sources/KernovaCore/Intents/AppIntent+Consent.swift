import AppIntents
import Foundation
import KernovaCommandModel

extension AppIntent {
    /// Runs a verb, raising the framework's own confirmation for each consent
    /// it refuses without (``VMConsentPolicy/run(prompting:_:)``), labelled
    /// with the core's own words, and answers what the verb returned.
    @MainActor
    @discardableResult
    func runWithConsent<Value>(_ body: (Consent) async throws -> Value) async throws -> Value {
        try await VMConsentPolicy.run(prompting: { try await confirm($0) }, body)
    }

    /// Raises the framework's confirmation for `prompt`.
    @MainActor
    private func confirm(_ prompt: ConfirmationPrompt) async throws {
        try await requestConfirmation(
            actionName: .custom(
                acceptLabel: "\(prompt.confirmTitle)",
                acceptAlternatives: [],
                denyLabel: "\(prompt.dismissTitle)",
                denyAlternatives: [],
                destructive: prompt.confirmIsDestructive),
            dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
    }
}
