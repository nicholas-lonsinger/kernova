import Foundation

/// The vmnet mode an app-managed network runs in.
public enum VmnetNetworkKind: String, Codable, CaseIterable, Sendable {
    /// Host Only: guests reach the host and the other guests on their network,
    /// never the LAN or the internet.
    case hostOnly
    /// NAT: guests reach the internet through the host's connection
    /// (NAT44/NAT66, DHCP, DNS proxy), and the host reaches them at the
    /// addresses they hold on its subnet.
    case shared
}

/// Which network of its mode a Shared or Host Only VM joins — membership,
/// which is what expresses guest↔guest reach (docs/NETWORKING.md).
///
/// Persisted as one string, ``rawValue``: `common`, `isolated`, or a named
/// network's identifier.
public enum VMNetworkMembership: Hashable, Sendable, Codable {
    /// The mode's common network, which every VM of the mode on it shares.
    case common
    /// A network of the VM's own, which no other guest joins.
    case isolated
    /// The named network with this identifier, which every VM of its kind
    /// naming it joins together.
    case network(UUID)

    /// ``rawValue`` for ``common``.
    public static let commonValue = "common"
    /// ``rawValue`` for ``isolated``.
    public static let isolatedValue = "isolated"

    /// The membership `rawValue` spells, `nil` for a string that spells none.
    public init?(rawValue: String) {
        switch rawValue {
        case Self.commonValue: self = .common
        case Self.isolatedValue: self = .isolated
        default:
            guard let id = UUID(uuidString: rawValue) else { return nil }
            self = .network(id)
        }
    }

    /// The persisted spelling, which the `network.membership` key reads and
    /// takes back.
    public var rawValue: String {
        switch self {
        case .common: Self.commonValue
        case .isolated: Self.isolatedValue
        case .network(let id): id.uuidString
        }
    }

    /// The named network this membership names, `nil` for the mode's common
    /// network and the VM's own.
    public var namedNetwork: UUID? {
        guard case .network(let id) = self else { return nil }
        return id
    }

    /// Reads the one string ``rawValue`` spells.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let membership = Self(rawValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(text) names no network membership")
        }
        self = membership
    }

    /// Writes ``rawValue``.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The network a VM is set to, as one value: what a Mode menu item selects,
/// what every surface naming the VM's network names, and what a library filter
/// matches.
///
/// `vmnet` is Shared Network or Host Only, on the network of that mode its
/// membership names. `bridged`'s payload is the host interface identifier,
/// `nil` for Automatic.
///
/// Coded as one string, ``rawValue``: `none`, `bridged`, `bridged:<interface>`,
/// or `<kind>:<membership>` (`shared:common`, `hostOnly:isolated`,
/// `shared:<network identifier>`).
public enum NetworkModeChoice: Hashable, Sendable, Codable {
    case vmnet(VmnetNetworkKind, VMNetworkMembership)
    case none
    case bridged(String?)

    /// Shared Network's common network.
    public static let shared = NetworkModeChoice.vmnet(.shared, .common)
    /// Host Only's common network.
    public static let hostOnly = NetworkModeChoice.vmnet(.hostOnly, .common)

    /// How a VM naming a named network reads it while the library's list of
    /// networks can't be read.
    public static let unreadableNetworkListTitle = "Network List Can\u{2019}t Be Read"

    private static let noneValue = "none"
    private static let bridgedValue = "bridged"

    /// Whether naming this choice takes the host's bridgeable interfaces, which
    /// only an enumeration answers.
    public var namesAHostInterface: Bool {
        if case .bridged(.some) = self { return true }
        return false
    }

    /// The choice `rawValue` spells, `nil` for a string that spells none.
    public init?(rawValue: String) {
        if rawValue == Self.noneValue {
            self = .none
            return
        }
        if rawValue == Self.bridgedValue {
            self = .bridged(nil)
            return
        }
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let head = String(rawValue[..<separator])
        let tail = String(rawValue[rawValue.index(after: separator)...])
        if head == Self.bridgedValue {
            guard !tail.isEmpty else { return nil }
            self = .bridged(tail)
            return
        }
        guard let kind = VmnetNetworkKind(rawValue: head),
            let membership = VMNetworkMembership(rawValue: tail)
        else { return nil }
        self = .vmnet(kind, membership)
    }

    /// The coded spelling.
    public var rawValue: String {
        switch self {
        case .none: Self.noneValue
        case .bridged(nil): Self.bridgedValue
        case .bridged(let identifier?): "\(Self.bridgedValue):\(identifier)"
        case .vmnet(let kind, let membership): "\(kind.rawValue):\(membership.rawValue)"
        }
    }

    /// Reads the one string ``rawValue`` spells.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let choice = Self(rawValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(text) names no network choice")
        }
        self = choice
    }

    /// Writes ``rawValue``.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
