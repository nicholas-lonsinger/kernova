import Foundation
import Synchronization

@testable import KernovaCore

/// Scripted stand-in for `Downloading`.
///
/// Contents ``setDownloadedContents(_:)`` set are written to the destination so
/// the caller's verification step has a real file to read; leaving them `nil` models the
/// skip-existing fast path, where the service returns without fetching because
/// the file is already there.
final class MockDownloadService: Downloading {
    private struct State {
        var downloadCallCount = 0
        var lastDownloadRemoteURL: URL?
        var lastDownloadDestinationURL: URL?
        var lastDownloadDiscardsExisting: Bool?
        var lastDownloadExpectedSizeBytes: UInt64?
        var adoptExistingFileCallCount = 0
        var lastAdoptSourceURL: URL?
        var lastAdoptDestinationURL: URL?
        var discardResumeDataCallCount = 0
        var discardedResumeDataURLs: [URL] = []
        var lastDiscardResumeDataPermanently: Bool?
        var downloadError: (any Error)?
        var downloadedContents: Data?
        var adoptExistingFileResult = true
        var progressSamples: [DownloadProgress] = []
    }

    private let state = Mutex(State())

    // MARK: - Recorded calls

    var downloadCallCount: Int { state.withLock { $0.downloadCallCount } }
    var lastDownloadRemoteURL: URL? { state.withLock { $0.lastDownloadRemoteURL } }
    var lastDownloadDestinationURL: URL? { state.withLock { $0.lastDownloadDestinationURL } }
    var lastDownloadDiscardsExisting: Bool? { state.withLock { $0.lastDownloadDiscardsExisting } }
    var lastDownloadExpectedSizeBytes: UInt64? { state.withLock { $0.lastDownloadExpectedSizeBytes } }
    var adoptExistingFileCallCount: Int { state.withLock { $0.adoptExistingFileCallCount } }
    var lastAdoptSourceURL: URL? { state.withLock { $0.lastAdoptSourceURL } }
    var lastAdoptDestinationURL: URL? { state.withLock { $0.lastAdoptDestinationURL } }
    var discardResumeDataCallCount: Int { state.withLock { $0.discardResumeDataCallCount } }
    /// URLs passed to `discardResumeData(at:permanently:)`, in call order.
    var discardedResumeDataURLs: [URL] { state.withLock { $0.discardedResumeDataURLs } }
    var lastDiscardResumeDataPermanently: Bool? { state.withLock { $0.lastDiscardResumeDataPermanently } }

    // MARK: - Scripting

    /// Sets the error every later download throws instead of downloading, per
    /// the per-method `<method>Error` convention.
    func setDownloadError(_ error: (any Error)?) {
        state.withLock { $0.downloadError = error }
    }

    /// Sets what every later download writes to the destination on success.
    func setDownloadedContents(_ contents: Data?) {
        state.withLock { $0.downloadedContents = contents }
    }

    /// Sets what `adoptExistingFile(at:as:)` answers. `true`, the default,
    /// really links the file, so the caller's later steps read a destination
    /// that exists; `false` models a destination another transfer owns, or a
    /// refused link.
    func setAdoptExistingFileResult(_ result: Bool) {
        state.withLock { $0.adoptExistingFileResult = result }
    }

    /// Sets the samples handed to the progress handler before a download
    /// returns.
    func setProgressSamples(_ samples: [DownloadProgress]) {
        state.withLock { $0.progressSamples = samples }
    }

    // MARK: - Downloading

    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        expectedSizeBytes: UInt64?,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let samples = state.withLock { state in
            state.downloadCallCount += 1
            state.lastDownloadRemoteURL = remoteURL
            state.lastDownloadDestinationURL = destinationURL
            state.lastDownloadDiscardsExisting = discardsExistingDownload
            state.lastDownloadExpectedSizeBytes = expectedSizeBytes
            return state.progressSamples
        }
        for sample in samples {
            await MainActor.run { progressHandler(sample) }
        }
        let (error, contents) = state.withLock { ($0.downloadError, $0.downloadedContents) }
        if let error { throw error }
        guard let contents else { return }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: destinationURL)
    }

    func adoptExistingFile(at sourceURL: URL, as destinationURL: URL) async -> Bool {
        let adopts = state.withLock { state in
            state.adoptExistingFileCallCount += 1
            state.lastAdoptSourceURL = sourceURL
            state.lastAdoptDestinationURL = destinationURL
            return state.adoptExistingFileResult
        }
        guard adopts else { return false }
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            return false
        }
        return true
    }

    func discardResumeData(at destinationURL: URL, permanently: Bool) {
        state.withLock { state in
            state.discardResumeDataCallCount += 1
            state.discardedResumeDataURLs.append(destinationURL)
            state.lastDiscardResumeDataPermanently = permanently
        }
    }
}
