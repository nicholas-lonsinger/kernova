import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCommandModel

@Suite("KernovaAppGroup identifier", .caseScoped)
struct AppGroupIdentifierTests {
    @Test("a team-prefixed group is the app's own")
    func teamPrefixedGroupMatches() {
        #expect(
            KernovaAppGroup.identifier(fromEntitlementGroups: ["8MT4P4GZL2.app.kernova"])
                == "8MT4P4GZL2.app.kernova")
    }

    @Test("a bare team prefix with no suffix is not a match")
    func bareTeamPrefixIsNotAMatch() {
        #expect(KernovaAppGroup.identifier(fromEntitlementGroups: ["8MT4P4GZL2"]) == nil)
    }
}
