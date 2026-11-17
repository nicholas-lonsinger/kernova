import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for the one free-name search.
@Suite("NameUniquing", .caseScoped)
struct NameUniquingTests {
    @Test("the bare search counts after the whole name, dots included")
    func countsAfterTheWholeName() {
        #expect(NameUniquing.firstAvailable("macOS 15.1") { $0 == "macOS 15.1" } == "macOS 15.1 2")
        #expect(NameUniquing.firstAvailable("free") { _ in false } == "free")
    }
}
