import Darwin
import Foundation
import Testing

@testable import Kernova

@Suite("HostARPTable Tests")
struct HostARPTableTests {
    // MARK: - Route messages, as the kernel lays them out

    /// One route message: an `rt_msghdr` naming `addresses`, then each socket
    /// address padded to a four-byte boundary.
    private static func message(addresses: Int32, expiry: Int32, _ sockaddrs: [[UInt8]]) -> [UInt8] {
        let body = sockaddrs.flatMap { $0 + [UInt8](repeating: 0, count: (4 - $0.count % 4) % 4) }
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        header.rtm_addrs = addresses
        header.rtm_rmx.rmx_expire = expiry
        return withUnsafeBytes(of: header) { Array($0) } + body
    }

    /// A `sockaddr_in` for `a.b.c.d`.
    private static func inet(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
    }

    /// A `sockaddr_dl` carrying `name` and the link-layer address `mac`.
    private static func link(_ mac: [UInt8], name: String = "") -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var data = nameBytes + mac
        if data.count < 12 { data += [UInt8](repeating: 0, count: 12 - data.count) }
        return [UInt8(8 + data.count), UInt8(AF_LINK), 5, 0, 6, UInt8(nameBytes.count), UInt8(mac.count), 0]
            + data
    }

    private static let destinationAndGateway = RTA_DST | RTA_GATEWAY
    private static let guestMAC: [UInt8] = [0x2e, 0x43, 0x28, 0x63, 0xbc, 0x2d]

    private static func parse(_ bytes: [UInt8]) -> [ARPEntry] {
        bytes.withUnsafeBytes { HostARPTableReader.parse($0) }
    }

    // MARK: - Parsing

    @Test("A complete entry yields its address, link-layer address and expiry")
    func aCompleteEntryParses() throws {
        let entries = Self.parse(
            Self.message(
                addresses: Self.destinationAndGateway, expiry: 1_790_126_894,
                [Self.inet(192, 168, 65, 16), Self.link(Self.guestMAC)]))

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(IPv4Value.string(entry.ipv4) == "192.168.65.16")
        #expect(entry.hardwareAddress == EthernetAddress("2e:43:28:63:bc:2d"))
        #expect(entry.expiry == 1_790_126_894)
    }

    @Test("An incomplete entry is skipped and the walk carries on past it")
    func anIncompleteEntryIsSkipped() {
        let incomplete = Self.message(
            addresses: Self.destinationAndGateway, expiry: 0,
            [Self.inet(192, 168, 65, 9), Self.link([])])
        let complete = Self.message(
            addresses: Self.destinationAndGateway, expiry: 1_790_000_000,
            [Self.inet(192, 168, 65, 10), Self.link(Self.guestMAC)])

        let entries = Self.parse(incomplete + complete)

        #expect(entries.map { IPv4Value.string($0.ipv4) } == ["192.168.65.10"])
    }

    @Test("A named link address pads to the boundary and the next message still parses")
    func aNamedLinkAddressKeepsTheWalkAligned() {
        let named = Self.message(
            addresses: Self.destinationAndGateway, expiry: 1_790_000_001,
            [Self.inet(192, 168, 128, 5), Self.link(Self.guestMAC, name: "bridge101")])
        let next = Self.message(
            addresses: Self.destinationAndGateway, expiry: 1_790_000_002,
            [Self.inet(192, 168, 128, 6), Self.link([0x02, 0, 0, 0, 0, 0x01])])

        let entries = Self.parse(named + next)

        #expect(entries.map(\.expiry) == [1_790_000_001, 1_790_000_002])
        #expect(entries.first?.hardwareAddress == EthernetAddress(octets: Self.guestMAC))
    }

    @Test("A message cut short ends the walk without reading past the buffer")
    func aTruncatedMessageEndsTheWalk() {
        let whole = Self.message(
            addresses: Self.destinationAndGateway, expiry: 1_790_000_000,
            [Self.inet(10, 0, 0, 2), Self.link(Self.guestMAC)])
        let cut = Array(whole.prefix(whole.count - 4))

        #expect(Self.parse(whole + cut).count == 1)
        #expect(Self.parse(cut).isEmpty)
    }

    @Test("The host's own table reads without an error")
    func theHostTableReads() {
        #expect(throws: Never.self) { try HostARPTableReader().entries() }
    }

    // MARK: - Ethernet addresses

    @Test("A MAC address parses in either case and with or without leading zeros")
    func macAddressSpellingsAgree() {
        let canonical = EthernetAddress("0a:bb:0c:01:02:03")
        #expect(canonical != nil)
        #expect(EthernetAddress("A:BB:C:1:2:3") == canonical)
        #expect(EthernetAddress(octets: [0x0a, 0xbb, 0x0c, 0x01, 0x02, 0x03]) == canonical)
    }

    @Test("Anything but six hexadecimal octets is no MAC address")
    func malformedMACAddressesAreRefused() {
        for text in [
            "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aa:bb:cc:dd:ee:gg", "aaa:bb:cc:dd:ee:ff", "",
            "+a:bb:cc:dd:ee:ff",
        ] {
            #expect(EthernetAddress(text) == nil, "\(text)")
        }
        #expect(EthernetAddress(octets: [1, 2, 3]) == nil)
    }
}
