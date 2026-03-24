import Foundation
import Virtualization
import os

/// Fetches and downloads macOS restore images (IPSWs) for macOS guest installation.
struct IPSWService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "IPSWService")

    // MARK: - Protocol Methods

    #if arch(arm64)
    /// Fetches the download URL for the latest supported macOS restore image.
    func fetchLatestRestoreImageURL() async throws -> URL {
        Self.logger.info("Fetching latest supported macOS restore image...")
        let restoreImage = try await VZMacOSRestoreImage.latestSupported
        return restoreImage.url
    }

    /// Downloads a macOS restore image from a remote URL to the specified destination.
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double, Int64, Int64) -> Void
    ) async throws {
        Self.logger.info("Downloading restore image from \(remoteURL, privacy: .public)")

        // RATIONALE: removeItem (not trashItem) is used here because these are incomplete/partial
        // IPSW files from a prior failed download — not user data worth preserving. Trashing
        // multi-gigabyte partial files would waste disk space and may fail on volumes without Trash.
        do {
            try FileManager.default.removeItem(at: destinationURL)
        } catch CocoaError.fileNoSuchFile {
            // No existing file to clean up — expected on first download.
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let delegate = IPSWDownloadDelegate(
                destinationURL: destinationURL,
                progressHandler: progressHandler,
                continuation: continuation
            )
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            session.downloadTask(with: remoteURL).resume()
        }

        Self.logger.info("Restore image downloaded to \(destinationURL.lastPathComponent, privacy: .public)")
    }

    /// Loads a restore image from a local IPSW file.
    func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await VZMacOSRestoreImage.image(from: url)
    }
    #endif
}

// MARK: - IPSWProviding

extension IPSWService: IPSWProviding {}

// MARK: - Download Delegate

#if arch(arm64)
/// URLSession delegate that handles IPSW download progress reporting and file placement.
// RATIONALE: @unchecked Sendable is safe because URLSession creates a serial delegate
// queue when delegateQueue is nil, guaranteeing all callbacks are serialised.
// No mutable state is accessed outside of delegate callbacks.
private final class IPSWDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "IPSWDownloadDelegate")
    private static let progressInterval: TimeInterval = 0.1  // 100 ms

    private let destinationURL: URL
    private let progressHandler: @MainActor @Sendable (Double, Int64, Int64) -> Void
    // RATIONALE: URLSession guarantees exactly one didCompleteWithError call per task,
    // so this continuation is always resumed exactly once.
    private let continuation: CheckedContinuation<Void, any Error>
    private var moveError: (any Error)?
    private var lastProgressReport: TimeInterval = 0

    init(
        destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double, Int64, Int64) -> Void,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
        self.continuation = continuation
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressReport >= Self.progressInterval else { return }
        lastProgressReport = now

        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = self.progressHandler
        Task { @MainActor in handler(fraction, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes the temporary file after this method returns,
        // so the move must happen synchronously here.
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            Self.logger.error("Failed to move IPSW from '\(location.path(percentEncoded: false), privacy: .public)' to '\(self.destinationURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)")
            self.moveError = error
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // Break URLSession's strong reference to the delegate.
        session.finishTasksAndInvalidate()

        if let error = error ?? moveError {
            Self.logger.error("Restore image download failed: \(error.localizedDescription, privacy: .public)")
            do {
                try FileManager.default.removeItem(at: destinationURL)
            } catch {
                Self.logger.warning("Failed to clean up partial download at '\(self.destinationURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
            continuation.resume(throwing: IPSWError.downloadFailed(error.localizedDescription))
        } else {
            let handler = self.progressHandler
            let received = task.countOfBytesReceived
            let expected = task.countOfBytesExpectedToReceive
            Task { @MainActor in handler(1.0, received, expected) }
            continuation.resume()
        }
    }
}
#endif

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let message):
            "Failed to download restore image: \(message)"
        }
    }
}
