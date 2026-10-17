import Foundation
import KernovaLogging

/// What this copy of Kernova's app bundle ships: where the copy lives, its
/// version and build number, the guest agent it bundles, its blank-disk
/// templates, the `kernova` tool, and the relaunch helper.
///
/// `AppDelegate` reads the app's once, through ``init(bundle:)``, and hands that
/// value to everything that asks; nothing else reads `Bundle.main` for them.
package struct AppBundleProducts: Sendable {
    /// The `.app` this process runs from.
    package let bundleURL: URL

    /// The host version a control Hello advertises to the guest agent.
    package let hostVersion: String

    /// The build number `Tools/set-build-number.sh` substitutes into
    /// Info.plist; `nil` is a build misconfiguration.
    package let buildNumber: String?

    /// The guest agent this host bundles.
    package let guestAgent: BundledGuestAgent

    /// The bundle resources are looked up in; `nil` when `bundleURL` holds no
    /// bundle, which ships none of them.
    private let resources: Bundle?

    /// Reads `bundle`'s products.
    package init(bundle: Bundle) {
        self.bundleURL = bundle.bundleURL
        self.hostVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "host"
        self.buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String
        if buildNumber == nil {
            #log(Self.logger, .fault, "CFBundleVersion not found in Info.plist")
            assertionFailure("CFBundleVersion not found in Info.plist")
        }
        self.guestAgent = BundledGuestAgent(bundle: bundle)
        self.resources = bundle
    }

    /// The products of the bundle at `bundleURL`, with the versions and agent
    /// given rather than read from it.
    package init(
        bundleURL: URL, hostVersion: String, buildNumber: String?, guestAgent: BundledGuestAgent
    ) {
        self.bundleURL = bundleURL
        self.hostVersion = hostVersion
        self.buildNumber = buildNumber
        self.guestAgent = guestAgent
        self.resources = Bundle(url: bundleURL)
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppBundleProducts")

    /// The compressed blank-disk template of `sizeInGB`, or `nil` if the
    /// bundle ships none of that size.
    package func diskTemplateURL(sizeInGB: Int) -> URL? {
        resources?.url(
            forResource: "BlankDisk-\(sizeInGB)GB.asif", withExtension: "lzfse", subdirectory: "DiskTemplates")
    }

    /// The helper that re-opens the app once this process exits, or `nil` if
    /// the bundle ships none.
    package var relaunchHelperURL: URL? {
        resources?.url(forAuxiliaryExecutable: "KernovaRelaunchHelper")
    }

    /// The installer for the `kernova` tool this bundle carries.
    package var commandLineTool: CommandLineToolInstaller {
        CommandLineToolInstaller(appBundleURL: bundleURL)
    }
}
