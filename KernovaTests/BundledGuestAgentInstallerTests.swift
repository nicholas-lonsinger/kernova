import Foundation
import Testing

@testable import KernovaCore

/// The guest agent's installer image is a build product inside the app, so
/// only the app as host has one to match.
@Suite("Bundled guest agent installer", .caseScoped)
struct BundledGuestAgentInstallerTests {
    @Test("isInstaller(of:) matches the app's bundled DMG path only")
    func bundledGuestAgentInstallerMatchesThePathOnly() throws {
        let agentPath = try #require(BundledGuestAgent(bundle: .main).installerDiskImageURL)
            .path(percentEncoded: false)
        #expect(RemovableMediaItem(path: agentPath, readOnly: true).isInstaller(of: BundledGuestAgent(bundle: .main)))
        #expect(
            !RemovableMediaItem(path: "/tmp/other.iso", readOnly: true)
                .isInstaller(of: BundledGuestAgent(bundle: .main)))
    }
}
