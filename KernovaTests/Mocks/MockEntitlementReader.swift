@testable import Kernova

/// Stand-in for `EntitlementReading` answering from an explicit key set.
struct MockEntitlementReader: EntitlementReading {
    /// Keys the signature is treated as claiming with a `true` value.
    var granted: Set<String> = []

    func hasEntitlement(_ key: String) -> Bool { granted.contains(key) }
}

extension EntitlementService {
    /// The shipping signature's answer: every restricted key claimed.
    static let entitled = EntitlementService(
        reader: MockEntitlementReader(granted: [
            "com.apple.vm.networking",
            "com.apple.developer.accessory-access.usb",
            "com.apple.developer.networking.topology-observation",
        ]))

    /// The default signing's answer: no restricted key claimed.
    static let unentitled = EntitlementService(reader: MockEntitlementReader())
}
