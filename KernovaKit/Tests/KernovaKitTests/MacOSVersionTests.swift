import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("MacOSVersion", .caseScoped)
struct MacOSVersionTests {
    @Test("Every rendered version parses back to itself")
    func renderThenParseRoundTrips() {
        for major in [0, 1, 9, 10, 12, 26, 100] {
            for minor in [0, 1, 9, 10, 99] {
                for patch in [0, 1, 9, 10] {
                    let version = MacOSVersion(major: major, minor: minor, patch: patch)
                    #expect(MacOSVersion(version.description) == version, "\(major).\(minor).\(patch)")
                }
            }
        }
    }
}
