import AppIntents
import Foundation
import KernovaCommandModel

/// An action whose verb can refuse without a consent.
protocol ConsentingIntent: AppIntent {
    /// Whether each consent the verb refuses without is asked for as it runs;
    /// off, every one is given up front, as `--yes` gives it. A `@Parameter`
    /// defaulting to `true`.
    var confirmsFirst: Bool { get }
}

extension ConsentingIntent {
    /// Runs a verb with every consent while ``confirmsFirst`` is off, and
    /// otherwise raises the framework's own confirmation for each consent it
    /// refuses without (``VMConsentPolicy/run(prompting:_:)``), labelled with
    /// the core's own words.
    @MainActor
    func runWithConsent(_ body: (Consent) async throws -> Void) async throws {
        guard confirmsFirst else { return try await body(.all) }
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
