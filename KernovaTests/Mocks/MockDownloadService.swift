import Foundation

@testable import Kernova

/// Scripted stand-in for `Downloading`.
///
/// `downloadedContents`, when set, is written to the destination so the caller's
/// verification step has a real file to read; leaving it `nil` models the
/// skip-existing fast path, where the service returns without fetching because
/// the file is already there.
final class MockDownloadService: Downloading, @unchecked Sendable {
    var downloadCallCount = 0
    var lastDownloadRemoteURL: URL?
    var lastDownloadDestinationURL: URL?
    var lastDownloadDiscardsExisting: Bool?
    var lastDownloadExpectedSizeBytes: UInt64?
    var adoptExistingFileCallCount = 0
    var lastAdoptSourceURL: URL?
    var lastAdoptDestinationURL: URL?
    var discardResumeDataCallCount = 0
    /// URLs passed to `discardResumeData(at:permanently:)`, in call order.
    var discardedResumeDataURLs: [URL] = []
    var lastDiscardResumeDataPermanently: Bool?

    /// Thrown instead of downloading, per the per-method `<method>Error` convention.
    var downloadError: (any Error)?

    /// Written to the destination on success.
    var downloadedContents: Data?

    /// What `adoptExistingFile(at:as:)` answers. `true` really links the file,
    /// so the caller's later steps read a destination that exists; `false`
    /// models a destination another transfer owns, or a refused link.
    var adoptExistingFileResult = true

    /// Samples handed to the progress handler before the download returns.
    var progressSamples: [DownloadProgress] = []

    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        expectedSizeBytes: UInt64?,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        downloadCallCount += 1
        lastDownloadRemoteURL = remoteURL
        lastDownloadDestinationURL = destinationURL
        lastDownloadDiscardsExisting = discardsExistingDownload
        lastDownloadExpectedSizeBytes = expectedSizeBytes
        for sample in progressSamples {
            await MainActor.run { progressHandler(sample) }
        }
        if let error = downloadError { throw error }
        guard let downloadedContents else { return }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try downloadedContents.write(to: destinationURL)
    }

    func adoptExistingFile(at sourceURL: URL, as destinationURL: URL) async -> Bool {
        adoptExistingFileCallCount += 1
        lastAdoptSourceURL = sourceURL
        lastAdoptDestinationURL = destinationURL
        guard adoptExistingFileResult else { return false }
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            return false
        }
        return true
    }

    func discardResumeData(at destinationURL: URL, permanently: Bool) {
        discardResumeDataCallCount += 1
        discardedResumeDataURLs.append(destinationURL)
        lastDiscardResumeDataPermanently = permanently
    }
}
