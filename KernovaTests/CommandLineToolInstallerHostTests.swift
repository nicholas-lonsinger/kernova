import Foundation
import KernovaKit
import Testing

@testable import KernovaCore

/// The installer over the tool a built Kernova.app carries, which only the app
/// as host has.
@Suite("Command line tool installer, in the app", .caseScoped)
struct CommandLineToolInstallerHostTests {
    /// The test host is a built Kernova.app, read as `KernovaApp` reads it.
    private let installer = AppBundleProducts(bundle: .main).commandLineTool

    @Test("The built app carries the tool the installer links to")
    func builtAppCarriesTheTool() {
        #expect(
            FileManager.default.fileExists(atPath: installer.bundledToolURL.path(percentEncoded: false)))
    }

    @Test("The offer follows the container the socket binds in")
    func availabilityFollowsTheContainer() {
        // One condition, read in one place: an Install button that could only
        // ever produce a tool reaching nothing is not offered at all.
        let hasContainer = KernovaAppGroup.containerURL() != nil
        let hasTool = FileManager.default.fileExists(
            atPath: installer.bundledToolURL.path(percentEncoded: false))
        #expect(installer.isAvailable == (hasContainer && hasTool))
    }
}
