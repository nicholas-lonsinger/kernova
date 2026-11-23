import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCommandModel

@Suite("UnixSocketAddress", .caseScoped)
struct UnixSocketAddressTests {
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

    /// Reads `sun_path` back as the NUL-terminated string it holds.
    private static func path(of address: inout sockaddr_un) -> String {
        withUnsafePointer(to: &address.sun_path) { rawPointer in
            rawPointer.withMemoryRebound(
                to: CChar.self, capacity: UnixSocketAddress.maxPathLength
            ) { String(cString: $0) }
        }
    }
}
