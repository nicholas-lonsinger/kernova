import Foundation
import Virtualization

/// The addresses a guest's network device can present, and the one validation
/// every writer of ``VMConfiguration/macAddress`` passes through.
enum GuestMACAddress {
    /// A fresh locally-administered unicast address.
    static func random() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }

    /// The canonical form of the MAC address `text` names — lowercase,
    /// colon-separated — or `nil` when it names none a guest can use.
    ///
    /// `VZMACAddress(string:)` takes six colon-separated hex pairs in either
    /// case and rejects every other spelling, so case is the only thing left to
    /// normalize. It also accepts the all-zero address and multicast/broadcast
    /// addresses, none of which a station can send from: a guest configured
    /// with one gets no link, and the app would key its reservation and
    /// forwarding rules on an address no frame can source
    /// (docs/NETWORKING.md principle 3 — refuse at entry what cannot take
    /// effect).
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = VZMACAddress(string: trimmed), address.isUnicastAddress,
            address.string != unspecified
        else { return nil }
        return address.string
    }

    /// The all-zero address, which parses and reads as unicast but addresses
    /// nothing.
    private static let unspecified = "00:00:00:00:00:00"
}
