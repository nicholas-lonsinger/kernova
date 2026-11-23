import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// What has to hold for a detached accessory to be recognised when macOS
/// assigns it back: the key is built from what survives a re-enumeration, it
/// says which of the two things it is, and two units that report the same
/// serial do not collapse onto one key.
@Suite("USB Accessory Identity Tests", .caseScoped)
struct USBAccessoryIdentityTests {
    private let descriptor = USBDeviceDescriptor(
        usbVersion: 0x0310, deviceClass: 0, deviceSubClass: 0, deviceProtocol: 0,
        vendorID: 0x04E8, productID: 0x6300, deviceVersion: 0x1100)

    private func node(
        serial: String? = nil, serialIndex: UInt8 = 0, ioPortPath: String? = nil,
        locationID: UInt32? = nil
    ) -> USBAccessoryNodeProperties {
        USBAccessoryNodeProperties(
            serialNumber: serial, serialNumberIndex: serialIndex, ioPortPath: ioPortPath,
            locationID: locationID)
    }

    // MARK: - Key Composition

    @Test("Prefers the receptacle path over the location when both are there")
    func receptaclePathWinsOverLocation() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(ioPortPath: "hub/Port-USB-C@2", locationID: 0x0120_0000),
                claimedBy: []))
        #expect(identity.key == "04e8:6300:1100@hub/Port-USB-C@2")
    }
}
