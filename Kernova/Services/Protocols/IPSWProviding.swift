import Foundation

/// Abstraction for IPSW (macOS restore image) fetching and downloading.
protocol IPSWProviding: Sendable {
    func fetchLatestRestoreImageURL() async throws -> URL
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws

    /// Deletes any persisted resume-data sidecar for the given destination path.
    ///
    /// Safe when no sidecar exists. `permanently` bypasses the Trash, so a
    /// "Delete Immediately" VM delete disposes of the partial download the
    /// same way.
    func discardResumeData(at destinationURL: URL, permanently: Bool)
}
