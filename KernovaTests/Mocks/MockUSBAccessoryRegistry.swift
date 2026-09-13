import Foundation

@testable import Kernova

/// Stand-in for `USBAccessoryRegistryReading` over an explicit table, so a test
/// can say what the IORegistry reports about an accessory — including that it
/// reports nothing.
struct MockUSBAccessoryRegistry: USBAccessoryRegistryReading {
    var propertiesByRegistryID: [UInt64: USBAccessoryNodeProperties] = [:]

    func properties(ofAccessory registryID: UInt64) -> USBAccessoryNodeProperties? {
        propertiesByRegistryID[registryID]
    }
}
