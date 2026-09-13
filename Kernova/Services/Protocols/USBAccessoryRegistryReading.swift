import Foundation

/// What an assigned USB accessory's IORegistry node says about the device
/// behind it.
///
/// Everything here survives a re-enumeration; nothing here is in the device
/// descriptor AccessoryAccess hands over, which carries the string *indices*
/// rather than the strings.
struct USBAccessoryNodeProperties: Sendable, Equatable {
    /// `kUSBVendorString` — what the device calls its maker.
    var vendorName: String?
    /// `kUSBProductString` — what the device calls itself.
    var productName: String?
    /// `kUSBSerialNumberString`, absent both when the device carries no serial
    /// and when the string did not come back. ``declaresSerialNumber``
    /// separates those.
    var serialNumber: String?
    /// `iSerialNumber` — the descriptor index, `0` when the device declares no
    /// serial at all.
    var serialNumberIndex: UInt8 = 0
    /// `UsbIOPort` from the port node above this one: the registry path of the
    /// service controlling the physical receptacle.
    ///
    /// One receptacle fronts a high-speed and a SuperSpeed port node carrying
    /// different `locationID`s, and both name the same `UsbIOPort` — so this
    /// is what stays put when a device comes back at another speed.
    var ioPortPath: String?
    /// `locationID` — the controller-and-port-path encoding, which stands in
    /// for the receptacle when the port node names none.
    var locationID: UInt32?

    /// Whether the device says it has a serial number.
    ///
    /// True with no ``serialNumber`` is the one case worth a log line: the
    /// device claims a serial Kernova could not read, so the identity falls
    /// back to the port for a reason the registry does not explain.
    var declaresSerialNumber: Bool { serialNumberIndex != 0 }

    /// The receptacle as a key names it — the whole `UsbIOPort` path, or the
    /// `locationID` when the port node carries none.
    var receptacleKey: String? {
        if let ioPortPath, !ioPortPath.isEmpty { return ioPortPath }
        return locationID.map { String(format: "%08x", $0) }
    }

    /// The receptacle as a person reads it — the last component of that path,
    /// which is what the hardware's own name for the port is.
    var receptacleLabel: String? {
        guard let receptacleKey else { return nil }
        return receptacleKey.split(separator: "/").last.map(String.init) ?? receptacleKey
    }
}

/// Reads the durable facts off the IORegistry node behind an assigned USB
/// accessory.
///
/// A property read opens no user client, so it takes the device from nobody
/// and needs no entitlement: the strings a device reports about itself are
/// already in the registry by the time macOS assigns the accessory. Opening it
/// to ask the same questions would take it exclusively and reset it on close,
/// which is why nothing here does.
protocol USBAccessoryRegistryReading: Sendable {
    /// What the node `registryID` names reports, or `nil` when no node answers
    /// to it.
    func properties(ofAccessory registryID: UInt64) -> USBAccessoryNodeProperties?
}
