import Foundation
import Testing
import Virtualization

@testable import Kernova
@testable import KernovaCore

@Suite("GuestMACAddress", .caseScoped)
struct GuestMACAddressTests {
    /// What the validation answered while `VZMACAddress` parsed it: the
    /// framework's reading of the trimmed text, kept only for a unicast address
    /// other than the all-zero one.
    private static func frameworkReading(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = VZMACAddress(string: trimmed), address.isUnicastAddress,
            address.string != "00:00:00:00:00:00"
        else { return nil }
        return address.string
    }

    @Test(
        "Every spelling reads the way VZMACAddress reads it",
        arguments: [
            "aa:bb:cc:dd:ee:ff", "AA:BB:CC:DD:EE:FF", "aA:Bb:cC:dD:eE:fF", "0a:0b:0c:0d:0e:0f",
            "02:00:00:00:00:01", " aa:bb:cc:dd:ee:ff\n", "a:b:c:d:e:f", "001:2:3:4:5:6",
            "aa-bb-cc-dd-ee-ff", "aabb.ccdd.eeff", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00",
            "aa:bb:cc:dd:ee:fg", "aa::cc:dd:ee:ff", ":aa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff:",
            "+a:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:-f", "aa:bb:cc:dd:ee: f", "\u{FF10}a:bb:cc:dd:ee:ff",
            "aa:bb:cc:dd:ee:ff\u{0}x", "", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01",
        ])
    func readsAsTheFrameworkDoes(_ text: String) {
        #expect(GuestMACAddress.normalized(text) == Self.frameworkReading(of: text))
    }

    @Test("A random address is a canonical, locally administered unicast one, as VZMACAddress reads it")
    func randomAddressIsLocallyAdministeredUnicast() throws {
        for _ in 0..<1_000 {
            let text = GuestMACAddress.random()
            let address = try #require(VZMACAddress(string: text))
            #expect(address.isLocallyAdministeredAddress)
            #expect(address.isUnicastAddress)
            #expect(address.string == text)
        }
    }
}
