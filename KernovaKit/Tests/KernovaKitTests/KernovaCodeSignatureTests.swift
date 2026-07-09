import Testing

@testable import KernovaKit

/// Unit tests for `KernovaCodeSignature.teamIdentifier()`.
///
/// The result depends on the test host's own code signature (unsigned,
/// ad-hoc, or team-signed depending on how the test target was built), so
/// this can't assert a specific value — under `swift test` / CI's
/// `CODE_SIGNING_ALLOWED=NO` the binary is unsigned and the value is `nil`.
/// It asserts the call doesn't trap in the `SecCode` FFI, and that any
/// non-nil result has the exact shape the entitlement/app-group substitution
/// and the XPC peer pin depend on (a 10-char uppercase-alphanumeric Team ID).
/// A stability/caching test is intentionally omitted: `teamIdentifier()` reads
/// a `static let` of the immutable running binary, so repeated calls are
/// trivially equal regardless of implementation — such a test would assert
/// nothing.
@Suite("KernovaCodeSignature")
struct KernovaCodeSignatureTests {
    @Test("Resolves without crashing, returning nil or a well-formed team ID")
    func resolvesWithoutCrashing() {
        guard let team = KernovaCodeSignature.teamIdentifier() else {
            return  // Unsigned/ad-hoc test host (e.g. CI) — an accepted outcome.
        }
        #expect(team.count == 10)
        #expect(team.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
    }
}
