import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("USB Accessory Info Tests", .caseScoped)
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

    // MARK: - Configuration Descriptor Parsing

    @Test("Walks past descriptors that are not interface descriptors")
    func skipsNonInterfaceDescriptors() {
        // An interface association descriptor (type 11) ahead of the interface.
        let filler: [UInt8] = [8, 11, 0, 2, 0x02, 0x02, 0x01, 0]
        let data = configurationBytes(interfaceClass: 0x02, leadingFiller: filler)
        #expect(USBConfigurationDescriptor.firstInterfaceClass(in: data) == 0x02)
    }

    // MARK: - Display Names

    @Test("Names the first interface's class when the device declares none of its own")
    func fallsBackToInterfaceClass() throws {
        let accessory = try info(
            descriptor: descriptorBytes(deviceClass: 0, vendorID: 0x04E8, productID: 0x6300),
            configuration: configurationBytes())
        #expect(accessory.displayName == "04e8:6300 · Mass storage")
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
}
