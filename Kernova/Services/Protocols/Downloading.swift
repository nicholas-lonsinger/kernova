import Foundation

/// Abstraction for the resumable file transfer every guest-setup pipeline
/// fetches its image through.
protocol Downloading: Sendable {
    /// Downloads the file at `remoteURL` to `destinationURL`, resuming a
    /// partial download already beside it and skipping over a completed one.
    ///
    /// `discardsExistingDownload` replaces what is at the destination instead:
    /// the file and its partial bundle are trashed as part of this call, so the
    /// disposal is serialized with any download already streaming there.
    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws

    /// Deletes any persisted resume sidecar for the given destination path.
    ///
    /// Safe when no sidecar exists. `permanently` bypasses the Trash, so a
    /// "Delete Immediately" VM delete disposes of the partial download the same
    /// way.
    func discardResumeData(at destinationURL: URL, permanently: Bool)
}
