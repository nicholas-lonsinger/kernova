import Foundation
import IOKit
import IOKit.usb

/// Reads an assigned accessory's IORegistry node through IOKit.
///
/// `registryID` resolves to the `IOUSBHostDevice` node itself, so one
/// `IORegistryEntryCreateCFProperties` answers every question but the
/// receptacle, which lives on the port node above it.
struct USBAccessoryRegistry: USBAccessoryRegistryReading {
    func properties(ofAccessory registryID: UInt64) -> USBAccessoryNodeProperties? {
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
    /// sits behind.
    ///
    /// Searched upward because the property belongs to the port node, not the
    /// device: a device is a child of the port it is plugged into.
    private func ioPortPath(above node: io_service_t) -> String? {
        IORegistryEntrySearchCFProperty(
            node, kIOServicePlane,
            kUSBHostPortPropertyIOPortServicePath as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) as? String
    }

    /// A descriptor index as the registry carries it — an `OSNumber` Kernova
    /// reads as one byte.
    private func byte(_ value: Any?) -> UInt8 {
        guard let number = value as? Int else { return 0 }
        return UInt8(truncatingIfNeeded: number)
    }
}
