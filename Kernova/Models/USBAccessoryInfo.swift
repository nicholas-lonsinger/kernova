import Foundation

/// The fields Kernova reads out of a USB device descriptor.
///
/// The wire layout is USB 2.0 §9.6.1 — 18 packed little-endian bytes, which
/// `IOUSBDeviceDescriptor` mirrors. `iManufacturer`/`iProduct`/`iSerialNumber`
/// are deliberately absent: they are string *indices*, and resolving them takes
/// control transfers on a device opened for exclusive access.
struct USBDeviceDescriptor: Sendable, Equatable {
    /// The USB revision the device reports, BCD-encoded (`0x0200` is USB 2.0).
    let usbVersion: UInt16
    let deviceClass: UInt8
    let deviceSubClass: UInt8
    let deviceProtocol: UInt8
    let vendorID: UInt16
    let productID: UInt16
    /// The device's own revision, BCD-encoded.
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

    /// The USB-IF name for `deviceClass`, or `nil` for a code the spec does not
    /// assign.
    ///
    /// `0x00` means the device declares no class of its own and each interface
    /// carries one instead, which is what "Composite" names.
    var className: String? {
        switch deviceClass {
        case 0x00: "Composite"
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

    /// `idVendor:idProduct`, the way every USB tool spells it.
    var vendorProductID: String {
        String(format: "%04x:%04x", vendorID, productID)
    }
}

/// A host USB accessory macOS has assigned to Kernova.
///
/// Runtime-only, never persisted. `registryID` is an IORegistry ID, which a
/// replug or a reboot reassigns, so it names an accessory only for as long as
/// this process keeps holding it.
struct USBAccessoryInfo: Sendable, Equatable, Identifiable {
    /// `AAUSBAccessory.registryID` — the handle every Kernova surface names
    /// this accessory by.
    let registryID: UInt64
    let descriptor: USBDeviceDescriptor

    var id: UInt64 { registryID }

    /// What the menu, the overview and `kernova usb list` call this accessory.
    ///
    /// A device's product and vendor strings are not readable without opening
    /// it for exclusive access, so this states the identifiers that are:
    /// `0403:6001 · Vendor-specific`, or the bare pair for an unassigned class
    /// code.
    var displayName: String {
        guard let className = descriptor.className else { return descriptor.vendorProductID }
        return "\(descriptor.vendorProductID) · \(className)"
    }
}

/// A passthrough device a running guest currently holds, and the accessory
/// behind it.
///
/// Runtime-only: the attachment lives no longer than the session, and nothing
/// re-creates it on restore.
struct AttachedUSBAccessory: Sendable, Equatable, Identifiable {
    /// The `VZUSBDevice.uuid` VZ minted for the attachment, and what a detach
    /// names.
    let deviceID: UUID
    let accessory: USBAccessoryInfo
    let attachedAt: Date

    var id: UUID { deviceID }

    init(deviceID: UUID, accessory: USBAccessoryInfo, attachedAt: Date = Date()) {
        self.deviceID = deviceID
        self.accessory = accessory
        self.attachedAt = attachedAt
    }
}
