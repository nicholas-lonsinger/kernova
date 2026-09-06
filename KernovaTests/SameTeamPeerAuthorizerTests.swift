import Foundation
import Testing

@testable import Kernova

/// The rule that decides whether a connecting peer is one this build answers.
///
/// The `SecCode` half needs a second signed process to exercise; this covers the
/// comparison it feeds, which is where the decision is actually made.
@Suite("Same-team peer authorizer", .admissionGated)
struct SameTeamPeerAuthorizerTests {
    @Test("The same team is admitted")
    func sameTeamIsAdmitted() {
        #expect(SameTeamPeerAuthorizer.isSameTeam(peer: "8MT4P4GZL2", own: "8MT4P4GZL2"))
    }

    @Test("Another team is refused")
    func otherTeamIsRefused() {
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "ABCDE12345", own: "8MT4P4GZL2"))
    }

    @Test("A peer naming no team is refused, however this build was signed")
    func adHocPeerIsRefused() {
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: nil, own: "8MT4P4GZL2"))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "", own: "8MT4P4GZL2"))
    }

    @Test("A build naming no team admits nobody, not everybody")
    func emptyOwnTeamAdmitsNobody() {
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "8MT4P4GZL2", own: ""))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: nil, own: ""))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "", own: ""))
    }

    @Test("The comparison is exact — a team is not a prefix match")
    func teamsMatchExactly() {
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "8MT4P4GZL", own: "8MT4P4GZL2"))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "8MT4P4GZL22", own: "8MT4P4GZL2"))
        #expect(!SameTeamPeerAuthorizer.isSameTeam(peer: "8mt4p4gzl2", own: "8MT4P4GZL2"))
    }
}
