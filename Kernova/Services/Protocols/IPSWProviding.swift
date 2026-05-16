import Foundation

/// Abstraction for IPSW (macOS restore image) fetching and downloading.
protocol IPSWProviding: Sendable {
    #if arch(arm64)
    func fetchLatestRestoreImageURL() async throws -> URL
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws

    /// Deletes any persisted resume-data sidecar for the given destination path.
    /// Called when an in-progress download is explicitly cancelled so the next
    /// attempt starts from scratch rather than resuming. Safe when no sidecar exists.
    func discardResumeData(at destinationURL: URL)
    #endif
}
