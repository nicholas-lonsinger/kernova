import Foundation
@testable import Kernova

/// No-op mock for `IPSWProviding`.
final class MockIPSWService: IPSWProviding, @unchecked Sendable {
    var fetchCallCount = 0
    var downloadCallCount = 0
    var discardResumeDataCallCount = 0
    var lastDiscardResumeDataURL: URL?
    var lastDiscardResumeDataPermanently: Bool?

    private static let mockRestoreImageURL: URL = {
        guard let url = URL(string: "https://example.com/restore.ipsw") else {
            assertionFailure("MockIPSWService: failed to construct mock restore image URL")
            return URL(filePath: "/")
        }
        return url
    }()

    var fetchError: (any Error)?
    var downloadError: (any Error)?

    func fetchLatestRestoreImageURL() async throws -> URL {
        fetchCallCount += 1
        if let error = fetchError { throw error }
        return Self.mockRestoreImageURL
    }

    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        downloadCallCount += 1
        if let error = downloadError { throw error }
    }

    func discardResumeData(at destinationURL: URL, permanently: Bool) {
        discardResumeDataCallCount += 1
        lastDiscardResumeDataURL = destinationURL
        lastDiscardResumeDataPermanently = permanently
    }
}
