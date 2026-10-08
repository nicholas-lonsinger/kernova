import Foundation
import KernovaKit

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
enum VMConsentPolicy {
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
    ///
    /// A prompt confirming to something other than what was asked for is
    /// rethrown instead (``isAnsweredByConfirming(_:)``).
    @MainActor
    static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        _ body: (Consent) async throws -> Void
    ) async throws {
        try await run(
            prompting: prompting,
            choosingMACAddressRemedy: { throw CommandError.macAddressRemedyRequired($0) },
            { consent, _ in try await body(consent) })
    }

    /// ``run(prompting:_:)`` for a bring-up, which also refuses over a MAC
    /// address another active VM uses on its network: a
    /// ``CommandError/macAddressRemedyRequired(_:)`` goes to
    /// `choosingMACAddressRemedy`, and `body` runs again carrying the remedy
    /// chosen beside every consent given so far.
    ///
    /// One loop rather than two nested ones, because the answers arrive in
    /// either order — a remedy can uncover a machine identity to confirm, and
    /// a confirmation can be asked before the conflict is reached — and each
    /// re-run has to carry both. One remedy per run: a second MAC address
    /// refusal is the remedy not having taken, and is rethrown. What
    /// `choosingMACAddressRemedy` throws is how a door says nobody chose.
    @MainActor
    static func run(
        prompting: (ConfirmationPrompt) async throws -> Void,
        choosingMACAddressRemedy: (MACAddressRemedyPrompt) async throws -> MACAddressRemedy,
        _ body: (Consent, MACAddressRemedy?) async throws -> Void
    ) async throws {
        var consent = Consent.none
        var remedy: MACAddressRemedy?
        while true {
            do {
                try await body(consent, remedy)
                return
            } catch let error as CommandError {
                if let prompt = error.confirmationPrompt, isAnsweredByConfirming(prompt),
                    !consent.covers(prompt.kind)
                {
                    try await prompting(prompt)
                    consent = consent.adding(prompt.kind)
                } else if let prompt = error.macAddressRemedyPrompt, remedy == nil,
                    !prompt.offers.isEmpty
                {
                    remedy = try await choosingMACAddressRemedy(prompt)
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
    /// ``VMCommanding/provideGuestAccountPassword(_:password:)`` or
    /// ``VMCommanding/skipGuestAccount(_:)`` — and `body` is then run again,
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
        case .forceStop, .deleteVM, .deleteSnapshot, .deleteEphemeralBaseline, .revertToSnapshot,
            .cancelPreparing, .cancelGuestSetup, .removeAttachment, .enableClipboardPassthrough,
            .startBesideSharedMachineIdentity:
            true
        }
    }

    /// The action that performs a revert with `takingCheckpoint` — its label and
    /// whether it destroys anything — `nil` when the VM cannot take one and so
    /// cannot perform that revert at all.
    ///
    /// The core names both routes — its own confirm action reverts, and a
    /// `takesCheckpoint` alternative captures first — and offers the
    /// alternative only where a capture can be taken. A surface that has
    /// already chosen between them shows the chosen one's words rather than
    /// inventing copy, and learns from the missing alternative that the choice
    /// cannot be honoured.
    ///
    /// Only the revert's own prompt carries that choice: any other consent a
    /// revert asks for — resuming beside a VM sharing its machine identity —
    /// is confirmed with its own words whatever was chosen.
    static func revertAction(
        _ prompt: ConfirmationPrompt, takingCheckpoint: Bool
    ) -> (title: String, isDestructive: Bool)? {
        guard takingCheckpoint, prompt.kind == .revertToSnapshot else {
            return (prompt.confirmTitle, prompt.confirmIsDestructive)
        }
        return prompt.alternatives.first { $0.takesCheckpoint }
            .map { ($0.title, $0.isDestructive) }
    }
}
