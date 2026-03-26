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
    #endif
}
