import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// What has to hold for a detached accessory to be recognised when macOS
/// assigns it back: the key is built from what survives a re-enumeration, it
/// says which of the two things it is, and two units that report the same
/// serial do not collapse onto one key.
@Suite("USB Accessory Identity Tests", .admissionGated)
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

    @Test("Builds the key from vendor, product, revision and serial")
    func serialKeyCarriesTheModelAndTheSerial() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor, node: node(serial: "0373025010003250", serialIndex: 3),
                claimedBy: []))
        #expect(identity.key == "04e8:6300:1100:0373025010003250")
        #expect(identity.form == .serialNumber)
    }

    @Test("Separates two revisions of one model")
    func revisionSeparatesTwoUnitsOfOneModel() throws {
        let older = USBDeviceDescriptor(
            usbVersion: descriptor.usbVersion, deviceClass: 0, deviceSubClass: 0,
            deviceProtocol: 0, vendorID: descriptor.vendorID, productID: descriptor.productID,
            deviceVersion: 0x0100)
        let first = USBAccessoryIdentity.make(
            descriptor: descriptor, node: node(serial: "S", serialIndex: 3), claimedBy: [])
        let second = USBAccessoryIdentity.make(
            descriptor: older, node: node(serial: "S", serialIndex: 3), claimedBy: [])
        #expect(first != second)
    }

    @Test("Keys a device that declares no serial on its receptacle")
    func noSerialFallsBackToTheReceptacle() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(ioPortPath: "IOService:/…/AppleHPMDevice@3F/Port-USB-C@2"),
                claimedBy: []))
        #expect(identity.key == "04e8:6300:1100@IOService:/…/AppleHPMDevice@3F/Port-USB-C@2")
        #expect(identity.form == .receptacle)
    }

    @Test("Keys on the location when the port node names no receptacle")
    func locationIDStandsInForTheReceptacle() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor, node: node(locationID: 0x0120_0000), claimedBy: []))
        #expect(identity.key == "04e8:6300:1100@01200000")
        #expect(identity.form == .receptacle)
    }

    @Test("Prefers the receptacle path over the location when both are there")
    func receptaclePathWinsOverLocation() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(ioPortPath: "hub/Port-USB-C@2", locationID: 0x0120_0000),
                claimedBy: []))
        #expect(identity.key == "04e8:6300:1100@hub/Port-USB-C@2")
    }

    @Test("Has no identity when neither a serial nor a port answers")
    func nothingDurableMeansNoIdentity() {
        #expect(USBAccessoryIdentity.make(descriptor: descriptor, node: node(), claimedBy: []) == nil)
    }

    @Test("Treats an empty serial string as no serial at all")
    func emptySerialIsNotASerial() throws {
        let identity = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "", serialIndex: 3, ioPortPath: "hub/Port-A@1"),
                claimedBy: []))
        #expect(identity.form == .receptacle)
    }

    // MARK: - Duplicate Serials

    @Test("Falls back to the receptacle when another accessory already answers to that serial")
    func aClaimedSerialIsNotReused() throws {
        let first = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@1"),
                claimedBy: []))
        let second = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@2"),
                claimedBy: [first.key]))
        #expect(first.form == .serialNumber)
        #expect(second.form == .receptacle)
        #expect(first != second)
    }

    @Test("Two units answering to one key in two receptacles are two identities")
    func theReceptacleSeparatesTwoUnitsSharingAKey() throws {
        // Composed blind of each other, as two accessories assigned while
        // neither is claimed: the key each takes is the same, and what tells
        // them apart is where each one is.
        let first = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@1"),
                claimedBy: []))
        let second = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@2"),
                claimedBy: []))
        #expect(first.key == second.key)
        #expect(first.receptacleKey == "hub/Port-A@1")
        #expect(first != second)
    }

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

    @Test("Keeps the serial key for a unit whose duplicate is already keyed on its port")
    func aPortKeyedDuplicateDoesNotClaimTheSerial() throws {
        // The order the two arrive in decides which form each takes, and the
        // one already handed out is never recomposed — so a key the first unit
        // is using has to still be free for it when it comes back.
        let portKeyed = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@2"),
                claimedBy: ["04e8:6300:1100:DUP"]))
        let returning = try #require(
            USBAccessoryIdentity.make(
                descriptor: descriptor,
                node: node(serial: "DUP", serialIndex: 3, ioPortPath: "hub/Port-A@1"),
                claimedBy: [portKeyed.key]))
        #expect(returning.key == "04e8:6300:1100:DUP")
        #expect(returning.form == .serialNumber)
    }

    // MARK: - Node Properties

    @Test("Separates a device with no serial from one whose serial did not come back")
    func declaresSerialNumberSeparatesTheTwoAbsences() {
        #expect(!node().declaresSerialNumber)
        #expect(node(serialIndex: 3).declaresSerialNumber)
    }

    @Test("Reads the receptacle label off the last path component")
    func receptacleLabelIsTheLastComponent() {
        #expect(node(ioPortPath: "IOService:/a/b/Port-USB-C@2").receptacleLabel == "Port-USB-C@2")
        #expect(node(locationID: 0x0120_0000).receptacleLabel == "01200000")
        #expect(node().receptacleLabel == nil)
    }
}
