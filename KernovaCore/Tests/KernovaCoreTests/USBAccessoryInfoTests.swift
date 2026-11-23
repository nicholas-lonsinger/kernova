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
}
