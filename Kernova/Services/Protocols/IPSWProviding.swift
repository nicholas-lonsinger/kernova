import Foundation

/// Looks up the macOS restore image (IPSW) a new guest installs by default.
protocol IPSWProviding: Sendable {
    /// The newest restore image Apple offers that this host can install.
    func fetchLatestRestoreImage() async throws -> LatestRestoreImage
}

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
