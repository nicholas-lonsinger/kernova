import Foundation
import IOKit
import IOKit.usb

/// Reads the durable facts off the IORegistry node behind an assigned USB
/// accessory, through IOKit.
///
/// A property read opens no user client, so it takes the device from nobody
/// and needs no entitlement: the strings a device reports about itself are
/// already in the registry by the time macOS assigns the accessory. Opening it
/// to ask the same questions would take it exclusively and reset it on close,
/// which is why nothing here does.
enum USBAccessoryRegistry {
    /// What the node `registryID` names reports, or `nil` when no node answers
    /// to it.
    ///
    /// `registryID` resolves to the `IOUSBHostDevice` node itself, so one
    /// `IORegistryEntryCreateCFProperties` answers every question but the
    /// receptacle, which lives on the port node above it.
    static func properties(ofAccessory registryID: UInt64) -> USBAccessoryNodeProperties? {
        let node = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard node != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(node) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(node, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
            let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return USBAccessoryNodeProperties(
            vendorName: properties[kUSBHostDevicePropertyVendorString] as? String,
            productName: properties[kUSBHostDevicePropertyProductString] as? String,
            serialNumber: properties[kUSBHostDevicePropertySerialNumberString] as? String,
            serialNumberIndex: byte(properties[kUSBHostDevicePropertySerialNumberStringIndex]),
            ioPortPath: ioPortPath(above: node),
            locationID: (properties[kUSBHostPropertyLocationID] as? Int).map {
                UInt32(truncatingIfNeeded: $0)
            })
    }

    /// The registry path of the service controlling the receptacle this node
    /// sits in.
    ///
    /// Read one level up because the property belongs to the port node, not the
    /// device: a device is a child of the port it is plugged into. Only that
    /// one level — a search up the whole parent chain answers for the
    /// machine's own receptacle from anywhere below it, which would give every
    /// device behind one hub the same key and make them one unit to anything
    /// matching on it. A hub's own ports carry no such property, so a device
    /// behind one has none here and is keyed by its `locationID` instead.
    private static func ioPortPath(above node: io_service_t) -> String? {
        var port: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &port) == KERN_SUCCESS,
            port != IO_OBJECT_NULL
        else { return nil }
        defer { IOObjectRelease(port) }

        return IORegistryEntryCreateCFProperty(
            port, kUSBHostPortPropertyIOPortServicePath as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// A descriptor index as the registry carries it — an `OSNumber` Kernova
    /// reads as one byte.
    private static func byte(_ value: Any?) -> UInt8 {
        guard let number = value as? Int else { return 0 }
        return UInt8(truncatingIfNeeded: number)
    }
}
