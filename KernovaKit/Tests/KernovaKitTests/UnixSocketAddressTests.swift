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
}
