import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("USB Accessory Info Tests", .admissionGated)
struct USBAccessoryInfoTests {
    /// A well-formed 18-byte device descriptor, USB 2.0 §9.6.1.
    ///
    /// Defaults describe an FTDI FT232 serial adapter — the device the feature
    /// was first exercised against, and a vendor-specific class.
    private func descriptorBytes(
        length: UInt8 = 18,
        descriptorType: UInt8 = 1,
        usbVersion: UInt16 = 0x0200,
        deviceClass: UInt8 = 0xFF,
        deviceSubClass: UInt8 = 0x00,
        deviceProtocol: UInt8 = 0x00,
        vendorID: UInt16 = 0x0403,
        productID: UInt16 = 0x6001,
        deviceVersion: UInt16 = 0x0600
    ) -> Data {
        var bytes: [UInt8] = [length, descriptorType]
        func appendWord(_ value: UInt16) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8(value >> 8))
        }
        appendWord(usbVersion)
        bytes.append(contentsOf: [deviceClass, deviceSubClass, deviceProtocol, 64])
        appendWord(vendorID)
        appendWord(productID)
        appendWord(deviceVersion)
        // iManufacturer, iProduct, iSerialNumber, bNumConfigurations.
        bytes.append(contentsOf: [1, 2, 3, 1])
        return Data(bytes)
    }

    /// A configuration descriptor followed by one interface descriptor, USB 2.0
    /// §9.6.3 — the shape `AAUSBAccessory.configurationDescriptorData` carries.
    private func configurationBytes(
        interfaceClass: UInt8 = 0x08, interfaceLength: UInt8 = 9, leadingFiller: [UInt8] = []
    ) -> Data {
        var bytes: [UInt8] = [9, 2, 32, 0, 1, 1, 0, 0xA0, 50]
        bytes.append(contentsOf: leadingFiller)
        bytes.append(contentsOf: [
            interfaceLength, 4, 0, 0, 2, interfaceClass, 0x06, 0x50, 0,
        ])
        return Data(bytes)
    }

    private func info(
        descriptor: Data, configuration: Data? = nil, node: USBAccessoryNodeProperties? = nil,
        registryID: UInt64 = 1, claimedBy held: [USBAccessoryInfo] = []
    ) throws -> USBAccessoryInfo {
        let parsed = try #require(USBDeviceDescriptor.parse(descriptor))
        return USBAccessoryInfo.make(
            registryID: registryID, descriptor: parsed, configurationDescriptor: configuration,
            node: node, claimedBy: held)
    }

    /// A node reporting a serial, in a named receptacle — the shape every
    /// question about which unit a key names is asked in.
    private func node(serial: String, in receptacle: String) -> USBAccessoryNodeProperties {
        USBAccessoryNodeProperties(
            serialNumber: serial, serialNumberIndex: 3, ioPortPath: receptacle)
    }

    // MARK: - Device Descriptor Parsing

    @Test("Parses every field little-endian")
    func parsesFieldsLittleEndian() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes()))
        #expect(descriptor.usbVersion == 0x0200)
        #expect(descriptor.deviceClass == 0xFF)
        #expect(descriptor.deviceSubClass == 0x00)
        #expect(descriptor.deviceProtocol == 0x00)
        #expect(descriptor.vendorID == 0x0403)
        #expect(descriptor.productID == 0x6001)
        #expect(descriptor.deviceVersion == 0x0600)
    }

    @Test("Reads the high byte of each word from the second position")
    func readsWordsLittleEndianNotBigEndian() throws {
        // Asymmetric so a byte-swapped read produces a different number rather
        // than the same one.
        let descriptor = try #require(
            USBDeviceDescriptor.parse(descriptorBytes(vendorID: 0x1234, productID: 0xABCD)))
        #expect(descriptor.vendorID == 0x1234)
        #expect(descriptor.productID == 0xABCD)
    }

    @Test("Reads a descriptor carrying trailing bytes")
    func parsesWithTrailingBytes() throws {
        var data = descriptorBytes()
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        let descriptor = try #require(USBDeviceDescriptor.parse(data))
        #expect(descriptor.vendorID == 0x0403)
    }

    @Test("Rejects a buffer shorter than a device descriptor")
    func rejectsShortBuffer() {
        let truncated = descriptorBytes().prefix(17)
        #expect(USBDeviceDescriptor.parse(Data(truncated)) == nil)
    }

    @Test("Rejects an empty buffer")
    func rejectsEmptyBuffer() {
        #expect(USBDeviceDescriptor.parse(Data()) == nil)
    }

    @Test("Rejects a bLength that disagrees with the spec")
    func rejectsWrongLengthField() {
        #expect(USBDeviceDescriptor.parse(descriptorBytes(length: 9)) == nil)
    }

    @Test("Rejects a descriptor that is not a device descriptor")
    func rejectsWrongDescriptorType() {
        // 2 is a configuration descriptor.
        #expect(USBDeviceDescriptor.parse(descriptorBytes(descriptorType: 2)) == nil)
    }

    // MARK: - Class Names

    @Test(
        "Names each assigned base class",
        arguments: [
            (UInt8(0x03), "Human interface"),
            (UInt8(0x08), "Mass storage"),
            (UInt8(0x09), "Hub"),
            (UInt8(0xE0), "Wireless controller"),
            (UInt8(0xFF), "Vendor-specific"),
        ])
    func namesAssignedClasses(code: UInt8, expected: String) throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes(deviceClass: code)))
        #expect(descriptor.className == expected)
    }

    @Test("Leaves an unassigned class code unnamed")
    func unassignedClassHasNoName() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes(deviceClass: 0x42)))
        #expect(descriptor.className == nil)
    }

    @Test("A zero class code is a statement that the interfaces carry the class")
    func zeroClassDefersToInterfaces() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes(deviceClass: 0)))
        #expect(descriptor.declaresClassPerInterface)
        #expect(descriptor.className == nil)
    }

    // MARK: - Configuration Descriptor Parsing

    @Test("Reads the first interface's class out of a configuration descriptor")
    func readsFirstInterfaceClass() {
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: configurationBytes()) == 0x08)
    }

    @Test("Walks past descriptors that are not interface descriptors")
    func skipsNonInterfaceDescriptors() {
        // An interface association descriptor (type 11) ahead of the interface.
        let filler: [UInt8] = [8, 11, 0, 2, 0x02, 0x02, 0x01, 0]
        let data = configurationBytes(interfaceClass: 0x02, leadingFiller: filler)
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: data) == 0x02)
    }

    @Test("Finds no interface class in bytes that carry none")
    func noInterfaceDescriptor() {
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: Data([9, 2, 9, 0, 0, 1, 0, 0xA0, 50])) == nil)
    }

    @Test("Refuses a descriptor chain with a zero length rather than looping")
    func zeroLengthDescriptorStops() {
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: Data([9, 2, 0, 0, 0, 0, 0, 0, 0, 0, 4])) == nil)
    }

    @Test("Refuses an interface descriptor that runs past the buffer")
    func truncatedInterfaceDescriptor() {
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: Data([9, 4, 0, 0])) == nil)
    }

    // MARK: - Display Names

    @Test("Formats the identifier pair zero-padded and lowercase")
    func formatsVendorProductID() throws {
        let descriptor = try #require(
            USBDeviceDescriptor.parse(descriptorBytes(vendorID: 0x005E, productID: 0x0B00)))
        #expect(descriptor.vendorProductID == "005e:0b00")
    }

    @Test("Names an accessory by what the device calls itself")
    func namesByReportedStrings() throws {
        let node = USBAccessoryNodeProperties(vendorName: "Samsung", productName: "Type-C")
        let accessory = try info(descriptor: descriptorBytes(deviceClass: 0), node: node)
        #expect(accessory.displayName == "Samsung Type-C")
    }

    @Test("Names an accessory by whichever of the two strings it reports")
    func namesByOneReportedString() throws {
        let node = USBAccessoryNodeProperties(productName: "Ultra Fit")
        let accessory = try info(descriptor: descriptorBytes(), node: node)
        #expect(accessory.displayName == "Ultra Fit")
    }

    @Test("Falls back to identifiers and class for a device that reports neither string")
    func fallsBackToIdentifiers() throws {
        let accessory = try info(descriptor: descriptorBytes())
        #expect(accessory.displayName == "0403:6001 · Vendor-specific")
    }

    @Test("Names the first interface's class when the device declares none of its own")
    func fallsBackToInterfaceClass() throws {
        let accessory = try info(
            descriptor: descriptorBytes(deviceClass: 0, vendorID: 0x04E8, productID: 0x6300),
            configuration: configurationBytes())
        #expect(accessory.displayName == "04e8:6300 · Mass storage")
    }

    @Test("Names an accessory by identifiers alone when nothing supplies a class")
    func displayNameOmitsUnknownClass() throws {
        let accessory = try info(descriptor: descriptorBytes(deviceClass: 0x42))
        #expect(accessory.displayName == "0403:6001")
    }

    @Test("A device declaring no class and offering no configuration is named by identifiers")
    func noClassAndNoConfiguration() throws {
        let accessory = try info(descriptor: descriptorBytes(deviceClass: 0))
        #expect(accessory.displayName == "0403:6001")
    }

    @Test("Identifies an accessory by its registry ID")
    func identityIsRegistryID() throws {
        #expect(try info(descriptor: descriptorBytes(), registryID: 99).id == 99)
    }

    // MARK: - Listing Names

    @Test("Leaves names alone when no two accessories read alike")
    func distinctNamesAreNotQualified() throws {
        let first = try info(
            descriptor: descriptorBytes(),
            node: USBAccessoryNodeProperties(productName: "Type-C", ioPortPath: "hub/Port-USB-C@2"),
            registryID: 1)
        let second = try info(
            descriptor: descriptorBytes(),
            node: USBAccessoryNodeProperties(productName: "Ultra Fit", ioPortPath: "hub/Port-A@1"),
            registryID: 2)
        let names = USBAccessoryInfo.listingNames(for: [first, second])
        #expect(names[1] == "Type-C")
        #expect(names[2] == "Ultra Fit")
    }

    @Test("Qualifies two accessories that would otherwise read identically")
    func duplicateNamesAreQualifiedByPort() throws {
        let node = USBAccessoryNodeProperties(
            vendorName: "Samsung", productName: "Type-C", ioPortPath: "hub/Port-USB-C@2")
        var other = node
        other.ioPortPath = "hub/Port-USB-C@3"
        let first = try info(descriptor: descriptorBytes(), node: node, registryID: 1)
        let second = try info(descriptor: descriptorBytes(), node: other, registryID: 2)
        let names = USBAccessoryInfo.listingNames(for: [first, second])
        #expect(names[1] == "Samsung Type-C (Port-USB-C@2)")
        #expect(names[2] == "Samsung Type-C (Port-USB-C@3)")
    }

    @Test("Leaves a duplicate unqualified when nothing names its port")
    func duplicateWithoutAPortKeepsItsName() throws {
        let node = USBAccessoryNodeProperties(vendorName: "Samsung", productName: "Type-C")
        let first = try info(descriptor: descriptorBytes(), node: node, registryID: 1)
        let second = try info(descriptor: descriptorBytes(), node: node, registryID: 2)
        let names = USBAccessoryInfo.listingNames(for: [first, second])
        #expect(names[1] == "Samsung Type-C")
        #expect(names[2] == "Samsung Type-C")
    }

    // MARK: - Keys Another Unit Already Holds

    @Test("An accessory coming back in the receptacle a key was taken from retakes it")
    func theEchoOfADetachRetakesItsKey() throws {
        let held = try info(descriptor: descriptorBytes(), node: node(serial: "0373", in: "hub/A@1"))
        // The same stick after the reset a detach causes: new registry ID, same
        // serial, same hole in the side of the machine. It has to answer to the
        // key the record still naming it carries, or that record can never be
        // reconciled and the capture that ejected it can never find it.
        let echo = try info(
            descriptor: descriptorBytes(), node: node(serial: "0373", in: "hub/A@1"),
            registryID: 2, claimedBy: [held])

        #expect(echo.identity == held.identity)
        #expect(echo.identity?.form == .serialNumber)
    }

    @Test("A second unit reporting the same serial elsewhere is keyed by its port instead")
    func aDuplicateSerialInAnotherReceptacleTakesTheWeakKey() throws {
        let held = try info(descriptor: descriptorBytes(), node: node(serial: "0373", in: "hub/A@1"))
        let second = try info(
            descriptor: descriptorBytes(), node: node(serial: "0373", in: "hub/A@2"),
            registryID: 2, claimedBy: [held])

        #expect(second.identity?.form == .receptacle)
        #expect(second.identity != held.identity)
    }

    // MARK: - Attachment

    @Test("Identifies an attachment by its device UUID")
    func attachmentIdentityIsDeviceID() throws {
        let deviceID = UUID()
        let attached = AttachedUSBAccessory(
            deviceID: deviceID, accessory: try info(descriptor: descriptorBytes()))
        #expect(attached.id == deviceID)
        #expect(attached.accessory.registryID == 1)
    }
}
