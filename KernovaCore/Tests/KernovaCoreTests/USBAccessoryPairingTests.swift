import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What a pairing matches, and what a set does when one is written or dropped.
@Suite("USB Accessory Pairing Tests", .caseScoped)
@MainActor
struct USBAccessoryPairingTests {
    private func pairing(
        key: String, form: USBAccessoryIdentity.Form, name: String = "Samsung Type-C",
        receptacleLabel: String? = "Port-USB-C@2"
    ) -> USBAccessoryPairing {
        USBAccessoryPairing(
            key: key, form: form, displayName: name, receptacleLabel: receptacleLabel,
            pairedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func identity(
        key: String, form: USBAccessoryIdentity.Form, receptacle: String?
    ) -> USBAccessoryIdentity {
        USBAccessoryIdentity(key: key, form: form, receptacleKey: receptacle)
    }

    // MARK: - Matching

    @Test("A key of one form does not answer for the other")
    func formIsPartOfTheMatch() {
        let set = USBAccessoryPairingSet(pairings: [pairing(key: "k", form: .serialNumber)])

        #expect(set.pairing(matching: identity(key: "k", form: .receptacle, receptacle: "p")) == nil)
    }

    // MARK: - Editing

    @Test("Upsert replaces the pairing already holding the key, in place")
    func upsertReplacesInPlace() {
        var set = USBAccessoryPairingSet(pairings: [
            pairing(key: "a", form: .serialNumber, name: "First"),
            pairing(key: "b", form: .serialNumber, name: "Second"),
        ])

        set.upsert(pairing(key: "a", form: .serialNumber, name: "First, renamed"))

        #expect(set.pairings.map(\.key) == ["a", "b"])
        #expect(set.pairings.first?.displayName == "First, renamed")
    }
}
