import Foundation

/// Abstraction for IPSW (macOS restore image) fetching and downloading.
protocol IPSWProviding: Sendable {
    /// The newest restore image Apple offers that this host can install.
    func fetchLatestRestoreImage() async throws -> LatestRestoreImage

    /// Downloads the image at `remoteURL` to `destinationURL`, resuming a
    /// partial download already beside it.
    ///
    /// `discardsExistingDownload` replaces what is at the destination instead:
    /// the image and its partial bundle are trashed as part of this call, so
    /// the disposal is serialized with any download already streaming there.
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws

    /// Deletes any persisted resume-data sidecar for the given destination path.
    ///
    /// Safe when no sidecar exists. `permanently` bypasses the Trash, so a
    /// "Delete Immediately" VM delete disposes of the partial download the
    /// same way.
    func discardResumeData(at destinationURL: URL, permanently: Bool)
}
