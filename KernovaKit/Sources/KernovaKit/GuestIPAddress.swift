import Foundation

/// What the guest's IPv4 address resolves to for the mode it is on — the one
/// answer every surface states, whether it renders prose or reports the bare
/// address.
///
/// The three non-address cases are distinct questions with distinct answers: a
/// guest that will never have an address the app can state, one whose address
/// belongs to somebody else's DHCP, and one whose reservation exists but whose
/// network has not published its addressing yet. Collapsing them to `nil`
/// leaves a caller unable to tell "there will never be one" from "not yet",
/// which is the difference between refusing and waiting.
public enum GuestIPAddress: Codable, Sendable, Hashable {
    /// Nothing assigns the guest an address the app can state — the row is
    /// absent rather than empty.
    case unavailable
    /// Bridged: the guest asks the network, so there is nothing deterministic.
    case externallyAssigned
    /// A reservation exists but the network's addressing is not known yet.
    case pending
    /// The address the app reserved for this guest.
    case reserved(String)

    /// The address itself, `nil` unless the app reserved one — what a surface
    /// answering with data alone reports, where the other cases are prose.
    public var reservedAddress: String? {
        guard case .reserved(let address) = self else { return nil }
        return address
    }
}
