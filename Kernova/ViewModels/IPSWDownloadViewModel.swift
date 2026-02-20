import Foundation
import os

/// Tracks the progress of an IPSW download operation.
@MainActor
@Observable
final class IPSWDownloadViewModel {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "IPSWDownloadViewModel")

    // MARK: - State

    var isDownloading = false
    var progress: Double = 0
    var downloadedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var errorMessage: String?

    var progressText: String {
        guard totalBytes > 0 else { return "Preparing..." }
        let downloaded = DataFormatters.formatBytesFixedWidth(downloadedBytes)
        let total = DataFormatters.formatBytesFixedWidth(totalBytes)
        return "\(downloaded) / \(total)"
    }

    var percentText: String {
        String(format: "%3d%%", Int(progress * 100))
            .replacingOccurrences(of: " ", with: "\u{2007}")
    }

    // MARK: - Download

    func updateProgress(_ fraction: Double) {
        progress = fraction
    }

    func startDownload() {
        isDownloading = true
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        errorMessage = nil
    }

    func finishDownload() {
        isDownloading = false
        progress = 1.0
    }

    func failDownload(with error: Error) {
        isDownloading = false
        errorMessage = error.localizedDescription
        Self.logger.error("IPSW download failed: \(error.localizedDescription)")
    }
}
