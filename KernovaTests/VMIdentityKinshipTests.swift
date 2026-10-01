import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMIdentityKinship Tests", .caseScoped)
@MainActor
struct VMIdentityKinshipTests {
    private static let identity = Data([1, 2, 3])

    private func makeVM(
        _ name: String, identity: Data?, mac: String?
    ) -> VMInstance {
        VMInstanceFixture.make(name: name) {
            $0.genericMachineIdentifierData = identity
            $0.macAddress = mac
        }
    }

    @Test("One machine identity and one MAC address, in any case, is an exact copy")
    func exactCopy() {
        let a = makeVM("A", identity: Self.identity, mac: "aa:bb:cc:dd:ee:01")
        let b = makeVM("B", identity: Self.identity, mac: "AA:BB:CC:DD:EE:01")
        #expect(a.kinship(with: b) == .exactCopy)
        #expect(b.kinship(with: a) == .exactCopy)
    }

    @Test("One machine identity and no MAC address on either is an exact copy")
    func exactCopyWithoutAddresses() {
        let a = makeVM("A", identity: Self.identity, mac: nil)
        let b = makeVM("B", identity: Self.identity, mac: nil)
        #expect(a.kinship(with: b) == .exactCopy)
    }

    @Test("One machine identity under different MAC addresses shares the identity only")
    func sharedMachineIdentity() {
        let a = makeVM("A", identity: Self.identity, mac: "aa:bb:cc:dd:ee:01")
        let b = makeVM("B", identity: Self.identity, mac: "aa:bb:cc:dd:ee:02")
        #expect(a.kinship(with: b) == .sharedMachineIdentity)
        #expect(makeVM("C", identity: Self.identity, mac: nil).kinship(with: a) == .sharedMachineIdentity)
    }

    @Test("One MAC address under different machine identities shares the address only")
    func sharedMACAddress() {
        let a = makeVM("A", identity: Self.identity, mac: "aa:bb:cc:dd:ee:01")
        let b = makeVM("B", identity: Data([9]), mac: "aa:bb:cc:dd:ee:01")
        let unidentified = makeVM("C", identity: nil, mac: "aa:bb:cc:dd:ee:01")
        #expect(a.kinship(with: b) == .sharedMACAddress)
        #expect(a.kinship(with: unidentified) == .sharedMACAddress)
    }

    @Test("Two VMs sharing neither, or carrying no identity or address, are no kin")
    func noKinship() {
        let a = makeVM("A", identity: Self.identity, mac: "aa:bb:cc:dd:ee:01")
        #expect(a.kinship(with: makeVM("B", identity: Data([9]), mac: "aa:bb:cc:dd:ee:02")) == nil)
        #expect(makeVM("C", identity: nil, mac: nil).kinship(with: makeVM("D", identity: nil, mac: nil)) == nil)
    }

    @Test("A bring-up configuration's address stands in for the VM's own")
    func bringUpConfigurationDecidesTheAddress() {
        let a = makeVM("A", identity: Self.identity, mac: "aa:bb:cc:dd:ee:01")
        let b = makeVM("B", identity: Self.identity, mac: "aa:bb:cc:dd:ee:02")
        var landing = a.configuration
        landing.macAddress = "aa:bb:cc:dd:ee:02"
        #expect(a.kinship(with: b, bringingUp: landing) == .exactCopy)
    }
}
