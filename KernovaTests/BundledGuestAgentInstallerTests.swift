import Foundation
import Testing

@testable import KernovaCore

/// The guest agent's installer image is a build product inside the app, so
/// only the app as host has one to match.
@Suite("Bundled guest agent installer", .caseScoped)
struct BundledGuestAgentInstallerTests {
    /// The test host's agent, read as `KernovaApp` reads it.
    private let agent = AppBundleProducts(bundle: .main).guestAgent

    @Test("isInstaller(of:) matches the app's bundled DMG path only")
    func bundledGuestAgentInstallerMatchesThePathOnly() throws {
        let agentPath = try #require(agent.installerDiskImageURL).path(percentEncoded: false)
        #expect(RemovableMediaItem(path: agentPath, readOnly: true).isInstaller(of: agent))
        #expect(!RemovableMediaItem(path: "/tmp/other.iso", readOnly: true).isInstaller(of: agent))
    }
}
