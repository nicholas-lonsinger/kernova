import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMConsentPolicy Tests", .caseScoped)
@MainActor
struct VMConsentPolicyTests {
    private func prompt(_ kind: ConfirmationKind) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: kind, title: "\(kind)?", message: "What \(kind) does.", confirmTitle: "Go",
            dismissTitle: "Cancel")
    }

    /// A verb refusing each of `needs` in turn until its consent covers it.
    private func verb(needing needs: [ConfirmationKind]) -> (Consent) throws -> Void {
        { consent in
            if let missing = needs.first(where: { !consent.covers($0) }) {
                throw CommandError.confirmationRequired(prompt(missing))
            }
        }
    }

    @Test("A verb needing two consents asks each with its own prompt, then runs with both")
    func asksEachConsentInTurn() async throws {
        var asked: [ConfirmationKind] = []
        var given: [Consent] = []
        let needs: [ConfirmationKind] = [.revertToSnapshot, .startBesideSharedMachineIdentity]

        try await VMConsentPolicy.run(prompting: { asked.append($0.kind) }) { consent in
            given.append(consent)
            try verb(needing: needs)(consent)
        }

        #expect(asked == needs)
        #expect(
            given == [
                .none, Consent([.revertToSnapshot]),
                Consent([.revertToSnapshot, .startBesideSharedMachineIdentity]),
            ])
    }

    @Test("A refusal for a consent already given is rethrown rather than asked again")
    func aRepeatedRefusalIsRethrown() async throws {
        var asked = 0
        let refusal = CommandError.confirmationRequired(prompt(.forceStop))

        await #expect(throws: refusal) {
            try await VMConsentPolicy.run(prompting: { _ in asked += 1 }) { _ in throw refusal }
        }
        #expect(asked == 1)
    }

    @Test("A declined prompt ends the loop with what the prompt threw")
    func aDeclinedPromptEndsTheLoop() async throws {
        struct Declined: Error {}
        var runs = 0

        await #expect(throws: Declined.self) {
            try await VMConsentPolicy.run(prompting: { _ in throw Declined() }) { consent in
                runs += 1
                try verb(needing: [.startBesideSharedMachineIdentity])(consent)
            }
        }
        #expect(runs == 1)
    }
}
