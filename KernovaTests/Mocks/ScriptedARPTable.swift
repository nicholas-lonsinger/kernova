import Foundation

@testable import Kernova

/// Scripted stand-in for `ARPTableReading`, so a test states the table the host
/// would hold instead of reading the real one. Empty until a test fills it.
final class ScriptedARPTable: ARPTableReading, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedEntries: [ARPEntry]
    private var scriptedError: (any Error)?
    private var reads = 0

    init(_ entries: [ARPEntry] = []) {
        scriptedEntries = entries
    }

    /// The entries every later read returns.
    var table: [ARPEntry] {
        get { lock.withLock { scriptedEntries } }
        set { lock.withLock { scriptedEntries = newValue } }
    }

    /// Thrown by every later read while set.
    var error: (any Error)? {
        get { lock.withLock { scriptedError } }
        set { lock.withLock { scriptedError = newValue } }
    }

    /// How many reads have run.
    var readCount: Int { lock.withLock { reads } }

    func entries() throws -> [ARPEntry] {
        try lock.withLock {
            reads += 1
            if let scriptedError { throw scriptedError }
            return scriptedEntries
        }
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
