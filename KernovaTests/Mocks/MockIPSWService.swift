import Foundation
@testable import Kernova

/// No-op mock for `IPSWProviding`.
final class MockIPSWService: IPSWProviding, @unchecked Sendable {
    var fetchCallCount = 0
    var downloadCallCount = 0
    var lastDownloadRemoteURL: URL?
    var lastDownloadDestinationURL: URL?
    var lastDownloadDiscardsExisting: Bool?
    var discardResumeDataCallCount = 0
    var lastDiscardResumeDataURL: URL?
    var lastDiscardResumeDataPermanently: Bool?

    var fetchError: (any Error)?
    var downloadError: (any Error)?

    /// Returned on success; defaults to a plausible newest release.
    var fetchResult = makeLatestImage()

    func fetchLatestRestoreImage() async throws -> LatestRestoreImage {
        fetchCallCount += 1
        if let error = fetchError { throw error }
        return fetchResult
    }

    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        downloadCallCount += 1
        lastDownloadRemoteURL = remoteURL
        lastDownloadDestinationURL = destinationURL
        lastDownloadDiscardsExisting = discardsExistingDownload
        if let error = downloadError { throw error }
    }

    func discardResumeData(at destinationURL: URL, permanently: Bool) {
        discardResumeDataCallCount += 1
        lastDiscardResumeDataURL = destinationURL
        lastDiscardResumeDataPermanently = permanently
    }
}

/// Builds the answer a latest-image lookup returns, defaulted so a test names
/// only what it cares about.
///
/// The default URL follows Apple's own convention, so the filename it derives
/// is the readable `UniversalMac_<version>_<build>_Restore.ipsw` rather than a
/// digest — pass `urlString` to exercise the off-convention path.
func makeLatestImage(
    version: String = "26.5.2",
    build: String = "25F84",
    urlString: String? = nil
) -> LatestRestoreImage {
    let resolved =
        urlString
        ?? "https://updates.cdn-apple.com/fullrestores/UniversalMac_\(version)_\(build)_Restore.ipsw"
    return LatestRestoreImage(
        url: URL(string: resolved) ?? URL(fileURLWithPath: "/"),
        version: version,
        build: build
    )
}
