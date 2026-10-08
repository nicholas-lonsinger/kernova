import Foundation
import KernovaKit
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

    // MARK: - MAC address remedy

    private func remedyPrompt(offers: [MACAddressRemedy] = MACAddressRemedy.allCases)
        -> MACAddressRemedyPrompt
    {
        let vm = VMSummary(
            id: UUID(), name: "Clone", status: "stopped", ipAddress: .unavailable,
            heldByAnotherCopy: false)
        return MACAddressRemedyPrompt(
            vm: vm, other: vm, verb: .start, title: "Duplicate MAC Address", message: "Choose:",
            offers: offers.map { MACAddressRemedyOffer(remedy: $0, title: "\($0)", isDestructive: false) },
            dismissTitle: "Cancel")
    }

    @Test("A remedy chosen rides every re-run beside the consents given, in whichever order they are asked")
    func remedyRidesBesideConsents() async throws {
        var given: [(Consent, MACAddressRemedy?)] = []
        let prompt = remedyPrompt()

        try await VMConsentPolicy.run(
            prompting: { _ in }, choosingMACAddressRemedy: { _ in .ownNetwork }
        ) { consent, remedy in
            given.append((consent, remedy))
            guard remedy != nil else { throw CommandError.macAddressRemedyRequired(prompt) }
            try verb(needing: [.startBesideSharedMachineIdentity])(consent)
        }

        #expect(given.map(\.0) == [.none, .none, Consent([.startBesideSharedMachineIdentity])])
        #expect(given.map(\.1) == [nil, .ownNetwork, .ownNetwork])
    }

    @Test("A second MAC address refusal after a remedy is rethrown rather than asked again")
    func aRepeatedRemedyRefusalIsRethrown() async throws {
        var asked = 0
        let refusal = CommandError.macAddressRemedyRequired(remedyPrompt())

        await #expect(throws: refusal) {
            try await VMConsentPolicy.run(
                prompting: { _ in },
                choosingMACAddressRemedy: { _ in
                    asked += 1
                    return .newAddress
                }
            ) { _, _ in throw refusal }
        }
        #expect(asked == 1)
    }

    @Test("A remedy refusal offering nothing, or met by a door that cannot choose, stands")
    func unanswerableRemedyRefusalStands() async throws {
        let empty = CommandError.macAddressRemedyRequired(remedyPrompt(offers: []))
        await #expect(throws: empty) {
            try await VMConsentPolicy.run(
                prompting: { _ in }, choosingMACAddressRemedy: { _ in .noNetwork }
            ) { _, _ in throw empty }
        }

        let offered = CommandError.macAddressRemedyRequired(remedyPrompt())
        await #expect(throws: offered) {
            try await VMConsentPolicy.run(prompting: { _ in }) { _ in throw offered }
        }
    }
}
