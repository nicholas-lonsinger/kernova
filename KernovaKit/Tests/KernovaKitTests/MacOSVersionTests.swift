import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("MacOSVersion", .caseScoped)
struct MacOSVersionTests {
    // MARK: - Parsing

    @Test(
        "Anything but one to three dot-separated runs of ASCII digits does not parse",
        arguments: [
            "", ".", "26.", ".6", "26..1", "26.6.1.0", "+26.6", "-26.6", "26.-1", " 26.6", "26.6 ", "26,6",
            "26.6a", "٢٦.٦", "Sequoia", "Version 26.0 (Build 25A123)", "99999999999999999999.0",
        ])
    func malformedShapesDoNotParse(text: String) {
        #expect(MacOSVersion(text) == nil)
    }

    // MARK: - Round trip

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
