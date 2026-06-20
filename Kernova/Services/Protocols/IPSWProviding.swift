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
    /// Called when an in-progress download is explicitly cancelled so the next
    /// attempt starts from scratch rather than resuming. Safe when no sidecar exists.
    /// `permanently` removes the bundle immediately (bypassing the Trash) so a
    /// "Delete Immediately" VM delete disposes of the partial download the same way.
    func discardResumeData(at destinationURL: URL, permanently: Bool)
}
