import Foundation

/// The fields Kernova reads out of a USB device descriptor.
///
/// The wire layout is USB 2.0 §9.6.1 — 18 packed little-endian bytes, which
/// `IOUSBDeviceDescriptor` mirrors. `iManufacturer`/`iProduct`/`iSerialNumber`
/// are deliberately absent: they are string *indices*, and the strings they
/// index are read off the IORegistry node instead — see
/// ``USBAccessoryNodeProperties``.
struct USBDeviceDescriptor: Sendable, Equatable {
    /// The USB revision the device reports, BCD-encoded (`0x0200` is USB 2.0).
    let usbVersion: UInt16
    let deviceClass: UInt8
    let deviceSubClass: UInt8
    let deviceProtocol: UInt8
    let vendorID: UInt16
    let productID: UInt16
    /// The device's own revision, BCD-encoded. Part of the durable identity,
    /// because it separates hardware revisions of one SKU.
    let deviceVersion: UInt16

    /// The descriptor's fixed size, and the only `bLength` a device descriptor
    /// carries.
    static let encodedLength = 18

    /// `bDescriptorType` for a device descriptor.
    private static let deviceDescriptorType: UInt8 = 1

    /// Reads a device descriptor from `data`, or returns `nil` when the bytes
    /// are not one.
    ///
    /// Rejects anything whose length or `bDescriptorType` disagrees with the
    /// spec rather than reading past it, so a truncated or mistyped buffer
    /// cannot surface as a plausible-looking VID:PID.
    static func parse(_ data: Data) -> USBDeviceDescriptor? {
        guard data.count >= encodedLength else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == UInt8(encodedLength), bytes[1] == deviceDescriptorType else { return nil }

        func word(at offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }

        return USBDeviceDescriptor(
            usbVersion: word(at: 2),
            deviceClass: bytes[4],
            deviceSubClass: bytes[5],
            deviceProtocol: bytes[6],
            vendorID: word(at: 8),
            productID: word(at: 10),
            deviceVersion: word(at: 12))
    }

    /// Whether each interface carries its own class instead of the device.
    ///
    /// USB 2.0 §9.6.1: a `bDeviceClass` of zero means the device declares no
    /// class of its own. A flash drive reports it, so the class worth naming
    /// sits on the interface — see ``USBConfigurationDescriptor``.
    var declaresClassPerInterface: Bool { deviceClass == 0 }

    /// The USB-IF name for `deviceClass`, or `nil` when the device declares no
    /// class of its own or reports a code the spec does not assign.
    var className: String? {
        guard !declaresClassPerInterface else { return nil }
        return USBClassCode.name(deviceClass)
    }

    /// `idVendor:idProduct`, the way every USB tool spells it.
    var vendorProductID: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// `idVendor:idProduct:bcdDevice`, the model prefix a durable identity is
    /// built on.
    var modelKey: String {
        String(format: "%04x:%04x:%04x", vendorID, productID, deviceVersion)
    }
}

/// The USB-IF base class codes, as they are named to a person.
enum USBClassCode {
    /// The USB-IF name for `code`, or `nil` for one the spec does not assign.
    ///
    /// `0x00` is absent on purpose: it is not a class, it is the statement that
    /// the interfaces carry the class.
    static func name(_ code: UInt8) -> String? {
        switch code {
        case 0x01: "Audio"
        case 0x02: "Communications"
        case 0x03: "Human interface"
        case 0x05: "Physical"
        case 0x06: "Imaging"
        case 0x07: "Printer"
        case 0x08: "Mass storage"
        case 0x09: "Hub"
        case 0x0A: "Communications data"
        case 0x0B: "Smart card"
        case 0x0D: "Content security"
        case 0x0E: "Video"
        case 0x0F: "Personal healthcare"
        case 0x10: "Audio/video"
        case 0x11: "Billboard"
        case 0x12: "USB-C bridge"
        case 0xDC: "Diagnostic"
        case 0xE0: "Wireless controller"
        case 0xEF: "Miscellaneous"
        case 0xFE: "Application-specific"
        case 0xFF: "Vendor-specific"
        default: nil
        }
    }
}

/// Reads a configuration descriptor's chain of descriptors, USB 2.0 §9.6.3.
///
/// The bytes are a configuration descriptor followed by every interface and
/// endpoint descriptor under it, each prefixed by its own `bLength` and
/// `bDescriptorType`.
enum USBConfigurationDescriptor {
    /// `bDescriptorType` for an interface descriptor.
    private static let interfaceDescriptorType: UInt8 = 4

    /// `bLength` of an interface descriptor, and the offset of its
    /// `bInterfaceClass`.
    private static let interfaceDescriptorLength: UInt8 = 9
    private static let interfaceClassOffset = 5

    /// `bInterfaceClass` of the first interface in `data`, or `nil` when the
    /// bytes carry no whole interface descriptor.
    ///
    /// The first interface is what names a device that declares no class of
    /// its own: a flash drive's is mass storage, and "Composite" names nothing
    /// the user would recognise.
    static func firstInterfaceClass(in data: Data) -> UInt8? {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 1 < bytes.count {
            let length = Int(bytes[offset])
            // A zero length would loop forever, and a descriptor running past
            // the buffer is not one this can read.
            guard length >= 2, offset + length <= bytes.count else { return nil }
            if bytes[offset + 1] == interfaceDescriptorType,
                bytes[offset] >= interfaceDescriptorLength
            {
                return bytes[offset + interfaceClassOffset]
            }
            offset += length
        }
        return nil
    }
}
