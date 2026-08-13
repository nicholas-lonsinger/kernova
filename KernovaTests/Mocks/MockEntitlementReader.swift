@testable import Kernova

/// Stand-in for `EntitlementReading` answering from an explicit key set.
struct MockEntitlementReader: EntitlementReading {
    /// Keys the signature is treated as claiming with a `true` value.
    var granted: Set<String> = []

    func hasEntitlement(_ key: String) -> Bool { granted.contains(key) }
}
