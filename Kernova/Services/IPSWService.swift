import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// Looks up the newest macOS restore image (IPSW) this host can install, as VZ
/// reports it; the image itself downloads through ``Downloading``.
struct IPSWService: Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "IPSWService")

    func fetchLatestRestoreImage() async throws -> LatestRestoreImage {
        #log(Self.logger, .info, "Fetching latest supported macOS restore image...")
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

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        }
    }
}
