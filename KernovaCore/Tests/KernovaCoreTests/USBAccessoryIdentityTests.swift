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

    // MARK: - Duplicate Serials

    @Test("Has no identity when the port key is claimed as well")
    func aClaimedPortKeyLeavesNothingToTake() {
        // Taking either would name a device that is somewhere else, which is
        // worse than having no durable key at all.
        #expect(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@1"),
                claimedBy: ["04e8:6300:1100:DUP", "04e8:6300:1100@hub/Port-A@1"]) == nil)
    }

    // MARK: - Node Properties

    @Test("Reads the receptacle label off the last path component")
    func receptacleLabelIsTheLastComponent() {
        #expect(node(ioPortPath: "IOService:/a/b/Port-USB-C@2").receptacleLabel == "Port-USB-C@2")
        #expect(node(locationID: 0x0120_0000).receptacleLabel == "01200000")
        #expect(node().receptacleLabel == nil)
    }
}
