import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("MacOSVersion", .caseScoped)
struct MacOSVersionTests {
    private func os(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    // MARK: - Rendering

    @Test("A zero patch component is left off")
    func zeroPatchIsLeftOff() {
        #expect(MacOSVersion(os(26, 6, 0)).description == "26.6")
        #expect(MacOSVersion(os(26, 0, 0)).description == "26.0")
    }

    @Test("A nonzero patch component is kept")
    func nonzeroPatchIsKept() {
        #expect(MacOSVersion(os(26, 5, 2)).description == "26.5.2")
        #expect(MacOSVersion(os(12, 0, 1)).description == "12.0.1")
    }

    // MARK: - Parsing

    @Test("One to three components parse, a missing one reading as zero")
    func oneToThreeComponentsParse() {
        #expect(MacOSVersion("26") == MacOSVersion(major: 26, minor: 0, patch: 0))
        #expect(MacOSVersion("26.6") == MacOSVersion(major: 26, minor: 6, patch: 0))
        #expect(MacOSVersion("12.0.1") == MacOSVersion(major: 12, minor: 0, patch: 1))
    }

    @Test(
        "Anything but one to three dot-separated runs of ASCII digits does not parse",
        arguments: [
            "", ".", "26.", ".6", "26..1", "26.6.1.0", "+26.6", "-26.6", "26.-1", " 26.6", "26.6 ", "26,6",
            "26.6a", "٢٦.٦", "Sequoia", "Version 26.0 (Build 25A123)", "99999999999999999999.0",
        ])
    func malformedShapesDoNotParse(text: String) {
        #expect(MacOSVersion(text) == nil)
    }

    // MARK: - Ordering

    @Test("Components compare as numbers, major first")
    func numericOrdering() throws {
        #expect(MacOSVersion(major: 12, minor: 10) > MacOSVersion(major: 12, minor: 3))
        #expect(MacOSVersion(major: 13, minor: 0) > MacOSVersion(major: 12, minor: 99, patch: 99))
        #expect(MacOSVersion(major: 26, minor: 0, patch: 1) > MacOSVersion(major: 26, minor: 0))
        #expect(try #require(MacOSVersion("26.0")) == #require(MacOSVersion("26.0.0")))
        let shuffled = ["12.3", "26.0.1", "12.10", "9.9.9", "26", "12.3.1"].compactMap(MacOSVersion.init)
        #expect(shuffled.sorted().map(\.description) == ["9.9.9", "12.3", "12.3.1", "12.10", "26.0", "26.0.1"])
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
