import Testing

@testable import KernovaKit

/// Unit tests for `KernovaCodeSignature.teamIdentifier()`.
///
/// The result depends on the test host's own code signature (unsigned,
/// ad-hoc, or team-signed depending on how the test target was built), so
/// this only asserts the call doesn't crash and that a non-nil result looks
/// like a real 10-character team ID — not a specific value.
@Suite("KernovaCodeSignature")
struct KernovaCodeSignatureTests {
    @Test("Resolves without crashing, returning nil or a well-formed team ID")
    func resolvesWithoutCrashing() {
        let team = KernovaCodeSignature.teamIdentifier()
        if let team {
            #expect(team.count == 10)
        }
    }

    @Test("Repeated calls return the same cached value")
    func repeatedCallsAreStable() {
        #expect(KernovaCodeSignature.teamIdentifier() == KernovaCodeSignature.teamIdentifier())
    }
}
