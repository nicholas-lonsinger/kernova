import AppIntents
import Foundation
import KernovaKit

extension AppIntent {
    /// Runs a verb, raising the framework's own confirmation for each consent
    /// it refuses without (``VMConsentPolicy/run(prompting:_:)``), labelled
    /// with the core's own words.
    @MainActor
    func runWithConsent(_ body: (Consent) async throws -> Void) async throws {
        try await VMConsentPolicy.run(prompting: { try await confirm($0) }, body)
    }

    /// ``runWithConsent(_:)`` for a bring-up, also asking which change
    /// to the VM's network a MAC address conflict takes — a choice among the
    /// refusal's offers, made at run time rather than as a stored parameter,
    /// since which ones are offered depends on the VM's state when it runs.
    @MainActor
    func runBringUpWithConsent(
        _ body: (Consent, MACAddressRemedy?) async throws -> Void
    ) async throws {
        try await VMConsentPolicy.run(
            prompting: { try await confirm($0) },
            choosingMACAddressRemedy: { prompt in
                // Built twice: the framework takes the array it is handed.
                let options = {
                    prompt.offers.map { offer in
                        IntentChoiceOption(
                            title: "\(offer.title)",
                            style: offer.isDestructive ? .destructive : .default)
                    }
                }
                let chosen = try await requestChoice(
                    between: options() + [.cancel],
                    dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
                guard let index = options().firstIndex(of: chosen) else {
                    throw CommandError.macAddressRemedyRequired(prompt)
                }
                return prompt.offers[index].remedy
            },
            body)
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
