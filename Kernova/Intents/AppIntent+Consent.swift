import AppIntents
import Foundation
import KernovaKit

extension AppIntent {
    /// Runs a verb, raising the framework's own confirmation for each consent
    /// it refuses without (``VMConsentPolicy/run(prompting:_:)``).
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
        _ body: (Consent) async throws -> Void
    ) async throws {
        try await VMConsentPolicy.run(prompting: { try await confirm($0, asking: asking) }, body)
    }

    /// ``runWithConsent(asking:_:)`` for a bring-up, also asking which change
    /// to the VM's network a MAC address conflict takes — a choice among the
    /// refusal's offers, made at run time rather than as a stored parameter,
    /// since which ones are offered depends on the VM's state when it runs.
    @MainActor
    func runBringUpWithConsent(
        asking: (ConfirmationPrompt) throws -> (title: String, isDestructive: Bool) = {
            ($0.confirmTitle, $0.confirmIsDestructive)
        },
        _ body: (Consent, MACAddressRemedy?) async throws -> Void
    ) async throws {
        try await VMConsentPolicy.run(
            prompting: { try await confirm($0, asking: asking) },
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
    private func confirm(
        _ prompt: ConfirmationPrompt,
        asking: (ConfirmationPrompt) throws -> (title: String, isDestructive: Bool)
    ) async throws {
        let accept = try asking(prompt)
        try await requestConfirmation(
            actionName: .custom(
                acceptLabel: "\(accept.title)",
                acceptAlternatives: [],
                denyLabel: "\(prompt.dismissTitle)",
                denyAlternatives: [],
                destructive: accept.isDestructive),
            dialog: IntentDialog(full: "\(prompt.message)", supporting: "\(prompt.title)"))
    }
}
