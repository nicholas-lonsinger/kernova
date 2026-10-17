import Foundation
import KernovaLogging

/// The Kernova guest agent a host bundles: its version and its installer
/// image, both build products the "Package Guest Agent DMG" build phase writes
/// into the app's Resources.
///
/// One of the ``AppBundleProducts``, which reads the app's.
package struct BundledGuestAgent: Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "KernovaMacOSAgentInfo")

    /// Filename of the version sidecar in `Kernova.app/Contents/Resources/`.
    private static let versionResourceName = "KernovaMacOSAgentVersion"
    private static let versionResourceExtension = "txt"

    /// Filename of the installer DMG in `Kernova.app/Contents/Resources/`.
    private static let dmgResourceName = "KernovaMacOSAgent"
    private static let dmgResourceExtension = "dmg"

    /// Label every attachment of the installer image carries, matching the
    /// volume name the "Package Guest Agent DMG" build phase gives it — so the
    /// name Kernova shows for the attachment is the name the guest shows for
    /// the mounted volume.
    package static let diskLabel = "Kernova Guest Agent"

    /// The version of the guest agent embedded in this build of the host;
    /// `nil` means the build phase didn't run or its output is missing.
    package let version: String?

    private let locateInstaller: @Sendable () -> URL?

    package init(version: String?, installerDiskImageURL: URL?) {
        self.version = version
        self.locateInstaller = { installerDiskImageURL }
    }

    /// Reads `bundle`'s version sidecar once, and finds its installer image on
    /// every ask.
    init(bundle: Bundle) {
        self.version = Self.version(in: bundle)
        self.locateInstaller = {
            bundle.url(forResource: Self.dmgResourceName, withExtension: Self.dmgResourceExtension)
        }
    }

    /// Filesystem URL of the guest agent installer DMG, or `nil` if missing.
    ///
    /// Resolved on every read, so it always reflects the running app bundle's
    /// location.
    package var installerDiskImageURL: URL? { locateInstaller() }

    /// Filesystem path of the guest agent installer DMG, if present.
    var installerPath: String? {
        installerDiskImageURL?.path(percentEncoded: false)
    }

    private static func version(in bundle: Bundle) -> String? {
        guard
            let url = bundle.url(
                forResource: versionResourceName,
                withExtension: versionResourceExtension
            )
        else {
            #log(logger, .fault, "KernovaMacOSAgentVersion.txt missing from app bundle")
            assertionFailure(
                "KernovaMacOSAgentVersion.txt missing — check 'Package Guest Agent DMG' build phase outputs")
            return nil
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                #log(logger, .fault, "KernovaMacOSAgentVersion.txt is empty")
                assertionFailure("KernovaMacOSAgentVersion.txt is empty")
                return nil
            }
            return trimmed
        } catch {
            #log(
                logger, .fault,
                "Failed to read KernovaMacOSAgentVersion.txt: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Failed to read KernovaMacOSAgentVersion.txt: \(error.localizedDescription)")
            return nil
        }
    }
}
