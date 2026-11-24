import Foundation

/// What the guest's IPv4 address resolves to for the mode it is on — the one
/// answer every surface states, whether it renders prose or reports the bare
/// address.
///
/// The three non-address cases are distinct questions with distinct answers: a
/// guest the app cannot see an address for at all, one whose address belongs to
/// somebody else's DHCP, and one the app is watching but has not seen on its
/// network. Collapsing them to `nil` leaves a caller unable to tell "there will
/// be none" from "not yet", which is the difference between refusing and
/// waiting.
public enum GuestIPAddress: Codable, Sendable, Hashable {
    /// Nothing the app can see states the guest's address — the row is absent
    /// rather than empty.
    case unavailable
    /// Bridged: the guest asks the network, so there is nothing deterministic.
    case externallyAssigned
    /// The guest is running on an app-managed network, and the host has not
    /// seen it use an address there.
    case notObserved
    /// The address the host last saw the guest use on its network.
    case observed(String)

    /// The address itself, `nil` unless one was observed — what a surface
    /// answering with data alone reports, where the other cases are prose.
    public var address: String? {
        guard case .observed(let address) = self else { return nil }
        return address
    }

    /// Why there is no address to state, `nil` for an observed one.
    public var absence: GuestAddressAbsence? {
        switch self {
        case .unavailable: .unavailable
        case .externallyAssigned: .externallyAssigned
        case .notObserved: .notObserved
        case .observed: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state, address
    }

    private enum State: String, Codable {
        case unavailable, externallyAssigned, notObserved, observed
    }

    private var state: State {
        switch self {
        case .unavailable: .unavailable
        case .externallyAssigned: .externallyAssigned
        case .notObserved: .notObserved
        case .observed: .observed
        }
    }

    /// Reads the shape ``encode(to:)`` writes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .unavailable: self = .unavailable
        case .externallyAssigned: self = .externallyAssigned
        case .notObserved: self = .notObserved
        case .observed: self = .observed(try container.decode(String.self, forKey: .address))
        }
    }

    /// Writes the case as `state`, beside the `address` only an observed one
    /// carries — the object `--format json` prints.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

/// A ``GuestIPAddress`` that states no address, by why.
public enum GuestAddressAbsence: String, Codable, Sendable, Hashable {
    /// ``GuestIPAddress/unavailable``.
    case unavailable
    /// ``GuestIPAddress/externallyAssigned``.
    case externallyAssigned
    /// ``GuestIPAddress/notObserved``.
    case notObserved

    /// Why Kernova states no address for the guest of the VM named `vm`.
    public func sentence(vm: String) -> String {
        let vm = "\u{201C}\(vm)\u{201D}"
        return switch self {
        case .unavailable: "Kernova has no address for \(vm)."
        case .externallyAssigned:
            "\(vm) is bridged, so your network assigns its address and Kernova cannot state it."
        case .notObserved: "Kernova has not seen \(vm) on its network."
        }
    }
}
