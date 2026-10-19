import Foundation
import KernovaCore
import KernovaKit
import KernovaLogging
import Virtualization

/// Looks up the newest macOS restore image (IPSW) this host can install, as VZ
/// reports it; the image itself downloads through ``Downloading``.
package struct IPSWService: Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "IPSWService")

    package init() {}

    package func fetchLatestRestoreImage() async throws -> LatestRestoreImage {
        Self.logger.log(.info, "Fetching latest supported macOS restore image...")
        let restoreImage = try await VZMacOSRestoreImage.latestSupported
        return LatestRestoreImage(
            url: restoreImage.url,
            version: KernovaOSVersion.displayString(restoreImage.operatingSystemVersion),
            build: restoreImage.buildVersion
        )
    }
}

// MARK: - IPSWProviding

extension IPSWService: IPSWProviding {}
