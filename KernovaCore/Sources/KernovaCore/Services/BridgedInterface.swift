import Foundation

/// A host interface that supports bridged networking.
package struct BridgedInterface: Equatable, Sendable {
    package let identifier: String
    let localizedDisplayName: String

    package init(identifier: String, localizedDisplayName: String) {
        self.identifier = identifier
        self.localizedDisplayName = localizedDisplayName
    }
}

package protocol BridgedInterfaceProviding: Sendable {
    /// Host interfaces currently available for bridging.
    func interfaces() -> [BridgedInterface]
    /// The identifier of the host's default-route (primary) interface, if known.
    func primaryInterfaceIdentifier() -> String?
}

package enum BridgedInterfaceSelection {
    /// The interface a Bridged choice bridges over, `nil` when the host offers
    /// none it may use — never another interface in place of the chosen one.
    ///
    /// A chosen interface (`persisted`) counts only while `available` lists
    /// it. Automatic (`persisted` nil) keeps `held`, the interface a live
    /// bridge is on, while it stays available, and otherwise takes `primary`,
    /// the default-route interface, when that is bridgeable.
    package static func interface(
        persisted: String?, held: String?, available: [String], primary: String?
    ) -> String? {
        if let persisted { return available.contains(persisted) ? persisted : nil }
        if let held, available.contains(held) { return held }
        if let primary, available.contains(primary) { return primary }
        return nil
    }
}
