import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("KernovaOSVersion", .caseScoped)
struct KernovaOSVersionTests {
    // MARK: - displayString

    @Test("A zero patch component is left off")
    func zeroPatchIsLeftOff() {
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)) == "26.6")
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == "26.0")
    }

    @Test("A nonzero patch component is kept")
    func nonzeroPatchIsKept() {
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2)) == "26.5.2")
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 1)) == "12.0.1")
    }

    // MARK: - numericVersion(in:)

    @Test("The version is extracted from operatingSystemVersionString in any locale")
    func versionExtractedFromLocalizedDisplayString() {
        #expect(KernovaOSVersion.numericVersion(in: "Version 26.0 (Build 25A123)") == "26.0")
        #expect(KernovaOSVersion.numericVersion(in: "Versión 26.0 (Compilación 25A123)") == "26.0")
        #expect(KernovaOSVersion.numericVersion(in: "バージョン 26.0.1 (ビルド 25A123)") == "26.0.1")
    }

    @Test("A value holding no digits reads as nil")
    func noDigitsReadsAsNil() {
        #expect(KernovaOSVersion.numericVersion(in: "macOS") == nil)
        #expect(KernovaOSVersion.numericVersion(in: "") == nil)
    }
}
