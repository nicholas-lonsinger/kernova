import FileProvider
import Testing

@testable import KernovaKit

/// Unit tests for `FileProviderConfig.host(teamIdentifier:)` — the team is
/// normally resolved at runtime via `KernovaCodeSignature.teamIdentifier()`
/// (#476), but the parameter lets tests exercise both the pinned and
/// skipped-pin paths without depending on the test host's own code signature.
@Suite("FileProviderConfig")
struct FileProviderConfigTests {
    @Test("host() pins the owner and extension requirements to the given team")
    func hostPinsToGivenTeam() {
        let config = FileProviderConfig.host(
            appGroupIdentifier: "SAMPLETEAM.app.kernova.test",
            teamIdentifier: "SAMPLETEAM")

        #expect(
            config.ownerCodeSigningRequirement
                == "identifier \"app.kernova\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"SAMPLETEAM\"")
        #expect(
            config.extensionCodeSigningRequirement
                == "identifier \"app.kernova.fileprovider\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"SAMPLETEAM\"")
    }

    @Test("host() skips peer validation when no team identifier is available")
    func hostSkipsPinWhenTeamIsNil() {
        let config = FileProviderConfig.host(
            appGroupIdentifier: "SAMPLETEAM.app.kernova.test",
            teamIdentifier: nil)

        #expect(config.ownerCodeSigningRequirement == nil)
        #expect(config.extensionCodeSigningRequirement == nil)
    }

    @Test("guest() never pins a peer requirement")
    func guestNeverPins() {
        let config = FileProviderConfig.guest(appGroupIdentifier: "SAMPLETEAM.app.kernova.test")

        #expect(config.ownerCodeSigningRequirement == nil)
        #expect(config.extensionCodeSigningRequirement == nil)
    }
}
