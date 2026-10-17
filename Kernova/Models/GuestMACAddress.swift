import Foundation

/// The addresses a guest's network device can present, and the one validation
/// every writer of ``VMConfiguration/macAddress`` passes through.
///
/// Spelled the way `VZMACAddress` spells and reads them, which the engine
/// lane's tests pin.
enum GuestMACAddress {
    /// A fresh locally-administered unicast address.
    static func random() -> String {
        var octets = (0..<6).map { _ in UInt8.random(in: .min ... .max) }
        // The first octet's two low bits: multicast off, locally administered on.
        octets[0] = octets[0] & 0b1111_1100 | 0b0000_0010
        return canonical(octets)
    }

    /// The canonical form of the MAC address `text` names — lowercase,
    /// colon-separated — or `nil` when it names none a guest can use.
    ///
    /// Takes six colon-separated hex pairs in either case and rejects every
    /// other spelling, so case is the only thing left to normalize. A parse
    /// alone also accepts the all-zero address and multicast/broadcast
    /// addresses, none of which a station can send from: a guest configured
    /// with one gets no link, and the host can never observe it on the network
    /// (docs/NETWORKING.md, refuse at entry what cannot take effect).
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let octets = octets(spelledBy: trimmed), octets[0] & 0b1 == 0,
            octets.contains(where: { $0 != 0 })
        else { return nil }
        return canonical(octets)
    }

    /// The six octets `text` spells as colon-separated hex pairs, read up to
    /// its first NUL as a C string is; `nil` for any other spelling.
    private static func octets(spelledBy text: String) -> [UInt8]? {
        let bytes = text.utf8.prefix { $0 != 0 }
        let pairs = bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard pairs.count == 6 else { return nil }
        var octets: [UInt8] = []
        for pair in pairs {
            guard pair.count == 2, let high = hexValue(pair.first), let low = hexValue(pair.last)
            else { return nil }
            octets.append(high << 4 | low)
        }
        return octets
    }

    private static func hexValue(_ byte: UInt8?) -> UInt8? {
        switch byte {
        case let byte? where (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte):
            byte - UInt8(ascii: "0")
        case let byte? where (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte):
            byte - UInt8(ascii: "a") + 10
        case let byte? where (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte):
            byte - UInt8(ascii: "A") + 10
        default:
            nil
        }
    }

    private static func canonical(_ octets: [UInt8]) -> String {
        octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
