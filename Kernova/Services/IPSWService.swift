import Foundation
import KernovaKit
import Virtualization
import os

/// Fetches and downloads macOS restore images (IPSWs) for macOS guest installation.
///
/// The transfer itself belongs to `DownloadService`; what stays here is the
/// macOS-specific part — what VZ says the newest installable image is.
struct IPSWService: Sendable {
    private static let logger = Logger(subsystem: "app.kernova", category: "IPSWService")

    private let downloadService: DownloadService

    init(
        sessionConfiguration: URLSessionConfiguration? = nil,
        fileSystem: any FileSystemOperating = FileManager.default
    ) {
        self.downloadService = DownloadService(
            sessionConfiguration: sessionConfiguration, fileSystem: fileSystem)
    }

    // MARK: - Protocol Methods

    func fetchLatestRestoreImage() async throws -> LatestRestoreImage {
        Self.logger.info("Fetching latest supported macOS restore image...")
        let restoreImage = try await VZMacOSRestoreImage.latestSupported
        return LatestRestoreImage(
            url: restoreImage.url,
            version: KernovaOSVersion.displayString(restoreImage.operatingSystemVersion),
            build: restoreImage.buildVersion
        )
    }

    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool = false,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        try await downloadService.download(
            from: remoteURL,
            to: destinationURL,
            discardsExistingDownload: discardsExistingDownload,
            progressHandler: progressHandler
        )
    }

    func discardResumeData(at destinationURL: URL, permanently: Bool = false) {
        downloadService.discardResumeData(at: destinationURL, permanently: permanently)
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
