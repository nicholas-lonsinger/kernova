import Foundation
import Testing

@testable import KernovaKit

@Suite("KernovaAppGroup identifier", .admissionGated)
struct AppGroupIdentifierTests {
    @Test("a team-prefixed group is the app's own")
    func teamPrefixedGroupMatches() {
        #expect(
            KernovaAppGroup.identifier(fromEntitlementGroups: ["8MT4P4GZL2.app.kernova"])
                == "8MT4P4GZL2.app.kernova")
    }

    @Test("an unprefixed group names no container this build can reach")
    func unprefixedGroupIsNotAMatch() {
        #expect(KernovaAppGroup.identifier(fromEntitlementGroups: ["app.kernova"]) == nil)
    }

    @Test("an empty claim resolves to nothing")
    func emptyGroupsResolveToNil() {
        #expect(KernovaAppGroup.identifier(fromEntitlementGroups: []) == nil)
    }

    @Test("a foreign group is not mistaken for this one")
    func foreignGroupIsNotAMatch() {
        #expect(
            KernovaAppGroup.identifier(fromEntitlementGroups: [
                "8MT4P4GZL2.app.kernova.probe", "ABCDE12345.com.example.shared",
                "8MT4P4GZL2.app.kernovakit",
            ]) == nil)
    }

    @Test("an unsubstituted TeamIdentifierPrefix resolves to nothing")
    func unsubstitutedPrefixIsNotAMatch() {
        #expect(
            KernovaAppGroup.identifier(fromEntitlementGroups: [
                "$(TeamIdentifierPrefix)app.kernova"
            ]) == nil)
    }

    @Test("the app's group is picked out of a claim carrying several")
    func picksTheAppsGroupFromSeveral() {
        #expect(
            KernovaAppGroup.identifier(fromEntitlementGroups: [
                "ABCDE12345.com.example.shared", "8MT4P4GZL2.app.kernova",
            ]) == "8MT4P4GZL2.app.kernova")
    }

    @Test("a bare team prefix with no suffix is not a match")
    func bareTeamPrefixIsNotAMatch() {
        #expect(KernovaAppGroup.identifier(fromEntitlementGroups: ["8MT4P4GZL2"]) == nil)
    }
}
