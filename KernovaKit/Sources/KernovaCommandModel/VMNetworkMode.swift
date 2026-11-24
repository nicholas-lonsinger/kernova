import Foundation

/// How an enabled network device attaches to the world.
public enum VMNetworkMode: String, Codable, Sendable, Equatable, CaseIterable {
    case nat
    case bridged
    case hostOnly

    /// How every surface the user reads names this mode.
    public var title: String {
        switch self {
        case .nat: "NAT"
        case .bridged: "Bridged"
        case .hostOnly: "Host Only"
        }
    }
}
