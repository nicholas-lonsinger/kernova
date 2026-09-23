import Darwin
import Foundation

/// A 48-bit Ethernet address, as the host's ARP table and a VM's configuration
/// each name one.
struct EthernetAddress: Hashable, Sendable {
    /// The six octets, the first one most significant.
    let rawValue: UInt64

    /// The address `octets` spell, `nil` unless there are exactly six.
    init?(octets: some Collection<UInt8>) {
        guard octets.count == 6 else { return nil }
        rawValue = octets.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The address `text` names as six colon-separated hexadecimal octets, in
    /// either case and with or without leading zeros; `nil` for any other
    /// spelling.
    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard (1...2).contains(part.count), part.allSatisfy(\.isHexDigit) else { return nil }
            return UInt8(part, radix: 16)
        }
        guard parts.count == octets.count else { return nil }
        self.init(octets: octets)
    }
}

/// One entry of the host's IPv4 ARP table that binds an address to a link-layer
/// address.
struct ARPEntry: Equatable, Sendable {
    /// The neighbor's IPv4 address, in host byte order.
    let ipv4: UInt32
    /// The link-layer address the entry binds it to.
    let hardwareAddress: EthernetAddress
    /// The Unix time the entry lapses at, `0` for a permanent one.
    let expiry: Int
}

/// Reads the host's IPv4 ARP table, abstracted so tests script it.
protocol ARPTableReading: Sendable {
    /// Every entry carrying a six-byte link-layer address. Blocks for one
    /// sysctl — never call on the main actor. Throws when the table cannot be
    /// read at all.
    func entries() throws -> [ARPEntry]
}

/// A routing-sysctl read of the ARP table that failed.
struct ARPTableReadError: Error, LocalizedError {
    /// The `errno` the sysctl left.
    let code: Int32

    var errorDescription: String? {
        "sysctl NET_RT_FLAGS failed: \(String(cString: strerror(code)))"
    }
}

/// The real `ARPTableReading`, over the routing sysctl
/// `{CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO}`.
struct HostARPTableReader: ARPTableReading {
    /// Room past the size the first call reports, for entries added before the
    /// copy runs; a table that outgrows it fails with `ENOMEM` and the next
    /// read tries again.
    private static let headroom = 4096

    func entries() throws -> [ARPEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
            throw ARPTableReadError(code: errno)
        }
        var length = size + Self.headroom
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &length, nil, 0)
        }
        guard status == 0 else { throw ARPTableReadError(code: errno) }
        return buffer.withUnsafeBytes {
            Self.parse(UnsafeRawBufferPointer(rebasing: $0.prefix(length)))
        }
    }

    /// The entries a `NET_RT_FLAGS` dump holds: one `rt_msghdr` per route, each
    /// followed by the socket addresses its `rtm_addrs` bits name, every one
    /// padded to a four-byte boundary.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> [ARPEntry] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var entries: [ARPEntry] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= bytes.count else { break }
            let addresses = UnsafeRawBufferPointer(
                rebasing: bytes[(offset + headerSize)..<(offset + length)])
            if let entry = entry(header, addresses: addresses) { entries.append(entry) }
            offset += length
        }
        return entries
    }

    /// The entry one route message describes, `nil` unless it carries an IPv4
    /// destination and a six-byte link-layer gateway.
    private static func entry(_ header: rt_msghdr, addresses: UnsafeRawBufferPointer) -> ARPEntry? {
        var ipv4: UInt32?
        var hardwareAddress: EthernetAddress?
        var cursor = 0
        for bit in 0..<RTAX_MAX where header.rtm_addrs & (1 << bit) != 0 {
            guard cursor + 2 <= addresses.count else { break }
            let length = Int(addresses[cursor])
            let family = Int32(addresses[cursor + 1])
            guard cursor + length <= addresses.count else { break }
            let flag = Int32(1) << bit
            if flag == RTA_DST, family == AF_INET, length >= 8 {
                // sockaddr_in: length, family, port (2), address (4, network order).
                ipv4 = (cursor + 4..<cursor + 8).reduce(UInt32(0)) { $0 << 8 | UInt32(addresses[$1]) }
            } else if flag == RTA_GATEWAY, family == AF_LINK, length >= 8 {
                // sockaddr_dl: length, family, index (2), type, name length,
                // address length, selector length, then the name and address.
                let nameLength = Int(addresses[cursor + 5])
                let addressLength = Int(addresses[cursor + 6])
                let start = cursor + 8 + nameLength
                if addressLength == 6, start + 6 <= cursor + length {
                    hardwareAddress = EthernetAddress(octets: addresses[start..<start + 6])
                }
            }
            cursor += roundedUp(length)
        }
        guard let ipv4, let hardwareAddress else { return nil }
        return ARPEntry(
            ipv4: ipv4, hardwareAddress: hardwareAddress, expiry: Int(header.rtm_rmx.rmx_expire))
    }

    /// `length` padded to the four-byte boundary a route message aligns each
    /// socket address to; an empty one still takes four bytes.
    private static func roundedUp(_ length: Int) -> Int {
        let alignment = MemoryLayout<UInt32>.size
        return length > 0 ? 1 + ((length - 1) | (alignment - 1)) : alignment
    }
}
