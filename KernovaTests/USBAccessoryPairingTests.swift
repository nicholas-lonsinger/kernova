import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// What a pairing matches, and what a set does when one is written or dropped.
@Suite("USB Accessory Pairing Tests", .admissionGated)
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

    @Test("A pairing answers to its own key and form")
    func matchesOnKeyAndForm() {
        let set = USBAccessoryPairingSet(pairings: [pairing(key: "k", form: .serialNumber)])

        #expect(
            set.pairing(matching: identity(key: "k", form: .serialNumber, receptacle: "p"))?.key
                == "k")
    }

    @Test("A serial-form rule follows the unit into another port")
    func aSerialRuleFollowsTheDevice() {
        let key = "04e8:6300:0100:0373"
        let set = USBAccessoryPairingSet(pairings: [pairing(key: key, form: .serialNumber)])

        // The key is the whole claim: the stick answers to it wherever it is
        // plugged in, which is the case this form exists for.
        #expect(
            set.pairing(matching: identity(key: key, form: .serialNumber, receptacle: "hub/Port@9"))
                != nil)
    }

    @Test("A receptacle-form rule does not follow the device out of its port")
    func aReceptacleRuleStaysWithThePort() {
        let set = USBAccessoryPairingSet(
            pairings: [pairing(key: "04e8:6300:0100@hub/Port-A@1", form: .receptacle)])

        // A receptacle key spells the port into the key itself, so a unit in
        // another hole composes a different key and matches nothing.
        #expect(
            set.pairing(
                matching: identity(
                    key: "04e8:6300:0100@hub/Port-A@2", form: .receptacle,
                    receptacle: "hub/Port-A@2")) == nil)
    }

    @Test("A key of one form does not answer for the other")
    func formIsPartOfTheMatch() {
        let set = USBAccessoryPairingSet(pairings: [pairing(key: "k", form: .serialNumber)])

        #expect(set.pairing(matching: identity(key: "k", form: .receptacle, receptacle: "p")) == nil)
    }

    @Test("An accessory with no durable identity can be paired with nothing")
    func anUnidentifiableAccessoryMakesNoPairing() {
        let accessory = MockUSBAccessoryService.accessory(registryID: 1)

        #expect(accessory.identity == nil)
        #expect(USBAccessoryPairing.make(for: accessory) == nil)
    }

    @Test("A pairing carries the name and port the device is listed under")
    func makeCarriesTheDescription() throws {
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "0373", receptacle: "hub/Port-USB-C@2", vendorName: "Samsung",
            productName: "Type-C")

        let made = try #require(USBAccessoryPairing.make(for: accessory))

        // Stored rather than derived, because neither is readable while the
        // device is in a drawer — which is the whole case the settings row for
        // it exists for.
        #expect(made.key == accessory.identity?.key)
        #expect(made.form == .serialNumber)
        #expect(made.displayName == "Samsung Type-C")
        #expect(made.receptacleLabel == "Port-USB-C@2")
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

    @Test("Upsert of a new key appends it")
    func upsertAppendsANewKey() {
        var set = USBAccessoryPairingSet()

        set.upsert(pairing(key: "a", form: .serialNumber))

        #expect(set.pairings.map(\.key) == ["a"])
        #expect(!set.isEmpty)
    }

    @Test("Remove drops the key and leaves the rest")
    func removeDropsOneKey() {
        var set = USBAccessoryPairingSet(pairings: [
            pairing(key: "a", form: .serialNumber), pairing(key: "b", form: .receptacle),
        ])

        set.remove(key: "a")

        #expect(set.pairings.map(\.key) == ["b"])
    }

    @Test("Removing a key nothing holds changes nothing")
    func removeOfAnAbsentKeyIsANoOp() {
        var set = USBAccessoryPairingSet(pairings: [pairing(key: "a", form: .serialNumber)])
        let before = set

        set.remove(key: "z")

        #expect(set == before)
    }
}
