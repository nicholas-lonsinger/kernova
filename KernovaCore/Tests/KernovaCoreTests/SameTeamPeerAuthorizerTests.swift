import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// The rule that decides whether a connecting peer is one this build answers.
///
/// The `SecCode` half needs a second signed process to exercise; this covers the
/// comparison it feeds, which is where the decision is actually made.
@Suite("Same-team peer authorizer", .caseScoped)
struct SameTeamPeerAuthorizerTests {
    @Test("A peer naming no team is refused, however this build was signed")
    func adHocPeerIsRefused() {
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: nil, own: "8MT4P4GZL2"))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "", own: "8MT4P4GZL2"))
    }
}
