import Foundation

/// A host interface that supports bridged networking.
struct BridgedInterface: Equatable, Sendable {
    let identifier: String
    let localizedDisplayName: String
}

protocol BridgedInterfaceProviding: Sendable {
    /// Host interfaces currently available for bridging.
    func interfaces() -> [BridgedInterface]
    /// The identifier of the host's default-route (primary) interface, if known.
    func primaryInterfaceIdentifier() -> String?
}

enum BridgedInterfaceSelection {
    /// Chooses the interface to bridge over: the persisted identifier when it is
    /// still available, else the primary interface; nil when neither resolves.
    static func choose(persisted: String?, available: [String], primary: String?) -> String? {
        if let persisted, available.contains(persisted) { return persisted }
        if let primary, available.contains(primary) { return primary }
        return nil
    }
}
