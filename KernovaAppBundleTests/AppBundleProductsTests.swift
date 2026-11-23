import CryptoKit
import Foundation
import KernovaCommandModel
import Security
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

    @Test("The built app carries the Linux agent for both scopes, readable and not executable")
    func builtAppCarriesTheLinuxAgent() throws {
        let entries = products.guestAgents.entries.values.filter { $0.fileURL.lastPathComponent == "kernova-agent" }
        #expect(entries.count == 2)
        let url = try #require(entries.first?.fileURL)
        #expect(url.path(percentEncoded: false).hasSuffix("Contents/Resources/GuestAgents/linux-arm64/kernova-agent"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
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
        try #require(Bundle(url: try url(named: name)))
    }

    /// The product `name`, which the build wrote beside this test bundle.
    static func url(named name: String) throws -> URL {
        let directory = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "\(name) is not in \(directory.path(percentEncoded: false))")
        return url
    }

    private final class Anchor {}
}
