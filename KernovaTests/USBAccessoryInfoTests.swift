import Foundation
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

    // MARK: - Parsing

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
            (UInt8(0x00), "Composite"),
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

    // MARK: - Display

    @Test("Formats the identifier pair zero-padded and lowercase")
    func formatsVendorProductID() throws {
        let descriptor = try #require(
            USBDeviceDescriptor.parse(descriptorBytes(vendorID: 0x005E, productID: 0x0B00)))
        #expect(descriptor.vendorProductID == "005e:0b00")
    }

    @Test("Names an accessory by identifiers and class")
    func displayNameCarriesClass() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes()))
        let info = USBAccessoryInfo(registryID: 4_294_968_000, descriptor: descriptor)
        #expect(info.displayName == "0403:6001 · Vendor-specific")
    }

    @Test("Names an accessory by identifiers alone when the class is unassigned")
    func displayNameOmitsUnknownClass() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes(deviceClass: 0x42)))
        let info = USBAccessoryInfo(registryID: 7, descriptor: descriptor)
        #expect(info.displayName == "0403:6001")
    }

    @Test("Identifies an accessory by its registry ID")
    func identityIsRegistryID() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes()))
        #expect(USBAccessoryInfo(registryID: 99, descriptor: descriptor).id == 99)
    }

    // MARK: - Attachment

    @Test("Identifies an attachment by its device UUID")
    func attachmentIdentityIsDeviceID() throws {
        let descriptor = try #require(USBDeviceDescriptor.parse(descriptorBytes()))
        let deviceID = UUID()
        let attached = AttachedUSBAccessory(
            deviceID: deviceID,
            accessory: USBAccessoryInfo(registryID: 1, descriptor: descriptor))
        #expect(attached.id == deviceID)
        #expect(attached.accessory.registryID == 1)
    }
}
