import Foundation
import Testing

@testable import KernovaKit

@Suite("KernovaOSVersion")
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

    @Test("An all-zero version still renders both leading components")
    func allZeroRendersTwoComponents() {
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)) == "0.0")
    }

    @Test("Multi-digit components are neither truncated nor padded")
    func multiDigitComponentsSurvive() {
        #expect(
            KernovaOSVersion.displayString(
                OperatingSystemVersion(majorVersion: 260, minorVersion: 10, patchVersion: 11))
                == "260.10.11")
    }

    // MARK: - current

    @Test("current renders the running system's decomposed version")
    func currentMatchesProcessInfo() {
        #expect(
            KernovaOSVersion.current
                == KernovaOSVersion.displayString(ProcessInfo.processInfo.operatingSystemVersion))
    }

    @Test("current carries only digits and dots, never a localized display string")
    func currentIsNumericOnly() {
        let reported = KernovaOSVersion.current
        #expect(!reported.isEmpty)
        #expect(reported.allSatisfy { $0.isNumber || $0 == "." })
    }

    // MARK: - numericVersion(in:)

    @Test("An already-numeric value is returned unchanged")
    func numericValuePassesThrough() {
        #expect(KernovaOSVersion.numericVersion(in: "26.0") == "26.0")
        #expect(KernovaOSVersion.numericVersion(in: "26.0.1") == "26.0.1")
        #expect(KernovaOSVersion.numericVersion(in: "6") == "6")
    }

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

    @Test("A trailing build suffix is dropped rather than folded into the version")
    func trailingSuffixIsDropped() {
        #expect(KernovaOSVersion.numericVersion(in: "6.8.0-31-generic") == "6.8.0")
    }
}
