import Darwin
import Foundation
import Testing

@testable import KernovaKit

@Suite("UnixSocketAddress", .admissionGated)
struct UnixSocketAddressTests {
    @Test("sun_path holds 104 bytes on Darwin")
    func maxPathLengthMatchesDarwin() {
        #expect(UnixSocketAddress.maxPathLength == 104)
    }

    @Test("a path one byte short of the cap is accepted")
    func acceptsPathBelowCap() throws {
        let path = String(repeating: "a", count: UnixSocketAddress.maxPathLength - 2)
        var address = try UnixSocketAddress.make(path: path)
        #expect(Self.path(of: &address) == path)
    }

    @Test("a path filling the cap with its terminator is accepted")
    func acceptsPathAtCap() throws {
        let path = String(repeating: "a", count: UnixSocketAddress.maxPathLength - 1)
        var address = try UnixSocketAddress.make(path: path)
        #expect(Self.path(of: &address) == path)
    }

    @Test("a path whose terminator does not fit is refused")
    func refusesPathAboveCap() {
        let path = String(repeating: "a", count: UnixSocketAddress.maxPathLength)
        #expect(
            throws: UnixSocketAddress.Failure.pathTooLong(
                length: UnixSocketAddress.maxPathLength + 1,
                max: UnixSocketAddress.maxPathLength)
        ) {
            try UnixSocketAddress.make(path: path)
        }
    }

    @Test("the address names the AF_UNIX family and its own size")
    func addressCarriesFamilyAndLength() throws {
        var address = try UnixSocketAddress.make(path: "/tmp/kernova-test.sock")
        #expect(address.sun_family == sa_family_t(AF_UNIX))
        #expect(address.sun_len == UInt8(MemoryLayout<sockaddr_un>.size))

        let length = UnixSocketAddress.withSockaddr(&address) { _, length in length }
        #expect(length == socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    @Test("withSockaddr hands the same bytes the address holds")
    func withSockaddrRebindsInPlace() throws {
        var address = try UnixSocketAddress.make(path: "/tmp/kernova-rebind.sock")
        let family = UnixSocketAddress.withSockaddr(&address) { socketAddress, _ in
            socketAddress.pointee.sa_family
        }
        #expect(family == sa_family_t(AF_UNIX))
    }

    /// Reads `sun_path` back as the NUL-terminated string it holds.
    private static func path(of address: inout sockaddr_un) -> String {
        withUnsafePointer(to: &address.sun_path) { rawPointer in
            rawPointer.withMemoryRebound(
                to: CChar.self, capacity: UnixSocketAddress.maxPathLength
            ) { String(cString: $0) }
        }
    }
}
