import Testing

@testable import KernovaProtocol

@Suite("KernovaVersionComparison")
struct KernovaVersionComparisonTests {
    // MARK: - isAtLeast

    @Test("Equal versions are at least each other")
    func equalIsAtLeast() {
        #expect(KernovaVersionComparison.isAtLeast("0.23.0", "0.23.0"))
    }

    @Test("Newer is at least older")
    func newerIsAtLeast() {
        #expect(KernovaVersionComparison.isAtLeast("0.23.1", "0.23.0"))
    }

    @Test("Older is not at least newer")
    func olderIsNotAtLeast() {
        #expect(!KernovaVersionComparison.isAtLeast("0.23.0", "0.23.1"))
    }

    @Test("Numeric ordering: 0.9.0 < 0.10.0")
    func numericOrdering() {
        #expect(!KernovaVersionComparison.isAtLeast("0.9.0", "0.10.0"))
        #expect(KernovaVersionComparison.isAtLeast("0.10.0", "0.9.0"))
    }

    @Test("Empty/whitespace reference is treated as at-least (no spurious outdated)")
    func emptyReferenceIsAtLeast() {
        #expect(KernovaVersionComparison.isAtLeast("0.1.0", ""))
        #expect(KernovaVersionComparison.isAtLeast("0.1.0", "   "))
    }

    // MARK: - updateState

    @Test("Empty host version → unknown")
    func emptyHostIsUnknown() {
        #expect(KernovaVersionComparison.updateState(own: "0.23.0", hostBundled: "") == .unknown)
    }

    @Test("Own equals host → up to date")
    func equalIsUpToDate() {
        #expect(
            KernovaVersionComparison.updateState(own: "0.23.0", hostBundled: "0.23.0") == .upToDate)
    }

    @Test("Own newer than host → up to date (downgraded host / dev build)")
    func newerIsUpToDate() {
        #expect(
            KernovaVersionComparison.updateState(own: "0.24.0", hostBundled: "0.23.0") == .upToDate)
    }

    @Test("Own older than host → update available with host version")
    func olderIsUpdateAvailable() {
        #expect(
            KernovaVersionComparison.updateState(own: "0.22.0", hostBundled: "0.23.0")
                == .updateAvailable(bundled: "0.23.0"))
    }

    @Test("updateState trims whitespace in the host version it reports")
    func updateStateTrims() {
        #expect(
            KernovaVersionComparison.updateState(own: "0.22.0", hostBundled: " 0.23.0 ")
                == .updateAvailable(bundled: "0.23.0"))
    }
}
