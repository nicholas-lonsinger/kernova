import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// What a built Kernova.app carries, found through the `AppBundleProducts`
/// lookups `KernovaApp` reads its own bundle with. The app is only read, never
/// run.
@Suite("The built app's bundle products", .caseScoped)
struct AppBundleProductsTests {
    private let products: AppBundleProducts

    init() throws {
        products = AppBundleProducts(bundle: try BuiltProducts.bundle(named: "Kernova.app"))
    }

    @Test("The guest agent's version sidecar names the agent the build packaged")
    func guestAgentVersionNamesTheAgentBuilt() throws {
        let agent = try BuiltProducts.bundle(named: "Kernova Guest Agent.app")
        let built = try #require(agent.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(products.guestAgent.version == built)
    }

    @Test("isInstaller(of:) matches the app's bundled installer image path only")
    func installerImageMatchesThePathOnly() throws {
        let agent = products.guestAgent
        let path = try #require(agent.installerDiskImageURL).path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(RemovableMediaItem(path: path, readOnly: true).isInstaller(of: agent))
        #expect(!RemovableMediaItem(path: "/tmp/other.iso", readOnly: true).isInstaller(of: agent))
    }

    @Test("The built app carries the tool the installer links to")
    func builtAppCarriesTheTool() {
        let tool = products.commandLineTool.bundledToolURL
        #expect(FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false)))
    }

    @Test("The built app carries the relaunch helper")
    func builtAppCarriesTheRelaunchHelper() throws {
        let helper = try #require(products.relaunchHelperURL)
        #expect(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)))
    }

    @Test("Every disk size offered has a blank-disk template in the built app")
    func everyOfferedSizeHasATemplate() {
        for size in VMGuestOS.allDiskSizes {
            #expect(products.diskTemplateURL(sizeInGB: size) != nil, "no \(size) GB template")
        }
    }
}

/// The products the build wrote beside this test bundle, which the target's
/// dependency on the app builds first.
private enum BuiltProducts {
    static func bundle(named name: String) throws -> Bundle {
        let directory = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
        return try #require(
            Bundle(url: directory.appendingPathComponent(name, isDirectory: true)),
            "\(name) is not in \(directory.path(percentEncoded: false))")
    }

    private final class Anchor {}
}
