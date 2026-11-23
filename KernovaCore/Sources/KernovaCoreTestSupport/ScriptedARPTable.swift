import Foundation
import Synchronization

@testable import KernovaCore

/// Scripted stand-in for `ARPTableReading`, so a test states the table the host
/// would hold instead of reading the real one. Empty until a test fills it.
final class ScriptedARPTable: ARPTableReading {
    private let state: Mutex<[ARPEntry]>

    init(_ entries: [ARPEntry] = []) {
        state = Mutex(entries)
    }

    /// Sets the entries every later read returns.
    func setTable(_ entries: [ARPEntry]) {
        state.withLock { $0 = entries }
    }

    func entries() throws -> [ARPEntry] {
        state.withLock { $0 }
    }
}

extension IPv4Value {
    /// The host-byte-order value of the dotted-quad `text`, `nil` when it names
    /// no IPv4 address.
    static func parse(_ text: String) -> UInt32? {
        var address = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }
}

extension IPv4Subnet {
    /// The block holding the dotted-quad `network` under `mask`.
    static func scripted(_ network: String, mask: String = "255.255.255.0") -> IPv4Subnet {
        guard let address = IPv4Value.parse(network), let maskValue = IPv4Value.parse(mask) else {
            preconditionFailure("unparseable scripted subnet \(network) \(mask)")
        }
        return IPv4Subnet(containing: address, mask: maskValue)
    }
}

extension ARPEntry {
    /// An expiry twenty minutes out on the wall clock — an entry the host just
    /// confirmed.
    static var freshExpiry: Int { Int(Date().timeIntervalSince1970) + 1200 }

    /// An entry binding the dotted-quad `address` to `mac`, lapsing at `expiry`.
    static func scripted(_ address: String, mac: String, expiry: Int) -> ARPEntry {
        guard let ipv4 = IPv4Value.parse(address), let hardwareAddress = EthernetAddress(mac) else {
            preconditionFailure("unparseable scripted ARP entry \(address) \(mac)")
        }
        return ARPEntry(ipv4: ipv4, hardwareAddress: hardwareAddress, expiry: expiry)
    }
}
