import Foundation
import Testing

@testable import KernovaCore

/// The guest agent's installer image is a build product inside the app, so
/// only the app as host has one to match.
@Suite("Bundled guest agent installer", .caseScoped)
struct BundledGuestAgentInstallerTests {
    @Test("isBundledGuestAgentInstaller matches the bundled DMG path only")
    func bundledGuestAgentInstallerMatchesThePathOnly() throws {
        let agentPath = try #require(BundledGuestAgent.testing.installerDiskImageURL)
            .path(percentEncoded: false)
        #expect(RemovableMediaItem(path: agentPath, readOnly: true).isBundledGuestAgentInstaller)
        #expect(
            !RemovableMediaItem(path: "/tmp/other.iso", readOnly: true)
                .isBundledGuestAgentInstaller)
    }
}
