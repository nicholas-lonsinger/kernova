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
    ///
    /// If a `<destinationURL>.resumedata` sidecar exists from a prior interrupted attempt,
    /// the download resumes from where it left off. On non-cancel failures (network drop,
    /// sleep timeout) the sidecar is written so a future attempt at the same path can resume.
    /// User-initiated cancellation drops any resume data and surfaces as `CancellationError`.
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        Self.logger.info("Downloading restore image from \(remoteURL, privacy: .public)")

        let sidecarURL = Self.resumeDataSidecarURL(for: destinationURL)
        let priorResumeData = try? Data(contentsOf: sidecarURL)
        if priorResumeData != nil {
            Self.logger.notice(
                "Resuming prior IPSW download from sidecar at '\(sidecarURL.lastPathComponent, privacy: .public)'"
            )
        }

        // nonisolated(unsafe) is needed because URLSessionDownloadTask is not Sendable,
        // but URLSessionTask.cancel() is documented as thread-safe. The onCancel closure
        // runs on an arbitrary thread; this is the only safe operation we perform on it.
        nonisolated(unsafe) var downloadTask: URLSessionDownloadTask?

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let delegate = IPSWDownloadDelegate(
                    destinationURL: destinationURL,
                    sidecarURL: sidecarURL,
                    progressHandler: progressHandler,
                    continuation: continuation
                )
                let session = URLSession(
                    configuration: .default,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task: URLSessionDownloadTask
                if let priorResumeData {
                    task = session.downloadTask(withResumeData: priorResumeData)
                } else {
                    task = session.downloadTask(with: remoteURL)
                }
                downloadTask = task

                // Close the race where the Task was cancelled before downloadTask
                // was assigned — onCancel would have seen nil and done nothing.
                // Resume the continuation directly because a never-started task
                // won't fire didCompleteWithError.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            downloadTask?.cancel()
        }

        Self.logger.info("Restore image downloaded to \(destinationURL.lastPathComponent, privacy: .public)")
    }

    /// Deletes any persisted resume-data sidecar for the given destination path.
    /// Safe to call when no sidecar exists.
    func discardResumeData(at destinationURL: URL) {
        let sidecarURL = Self.resumeDataSidecarURL(for: destinationURL)
        do {
            try FileManager.default.removeItem(at: sidecarURL)
            Self.logger.info(
                "Discarded resume-data sidecar at '\(sidecarURL.lastPathComponent, privacy: .public)'"
            )
        } catch CocoaError.fileNoSuchFile {
            // Nothing to discard — common case.
        } catch {
            Self.logger.warning(
                "Failed to discard resume-data sidecar at '\(sidecarURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the on-disk location where URLSession resume data is persisted for a given
    /// download destination. Lives next to the final file so cleanup tracks the user's chosen path.
    static func resumeDataSidecarURL(for destinationURL: URL) -> URL {
        destinationURL.appendingPathExtension("resumedata")
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
    private let sidecarURL: URL
    private let progressHandler: @MainActor @Sendable (DownloadProgress) -> Void
    // RATIONALE: URLSession guarantees exactly one didCompleteWithError call per task,
    // so this continuation is always resumed exactly once.
    private let continuation: CheckedContinuation<Void, any Error>
    private var moveError: (any Error)?
    private var lastProgressReport: TimeInterval = 0
    private var previousBytesWritten: Int64 = 0
    private var smoothedBytesPerSecond: Double = 0
    /// EWMA smoothing factor — lower values produce smoother output.
    private static let smoothingAlpha: Double = 0.2

    init(
        destinationURL: URL,
        sidecarURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.destinationURL = destinationURL
        self.sidecarURL = sidecarURL
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

        let elapsed = now - lastProgressReport
        if elapsed > 0, lastProgressReport > 0 {
            let deltaBytes = Double(totalBytesWritten - previousBytesWritten)
            guard deltaBytes >= 0 else {
                Self.logger.warning(
                    "Negative byte delta detected (\(totalBytesWritten) < \(self.previousBytesWritten)) — skipping speed sample"
                )
                previousBytesWritten = totalBytesWritten
                lastProgressReport = now
                return
            }
            let instantSpeed = deltaBytes / elapsed
            if smoothedBytesPerSecond == 0 {
                smoothedBytesPerSecond = instantSpeed
            } else {
                smoothedBytesPerSecond =
                    Self.smoothingAlpha * instantSpeed
                    + (1 - Self.smoothingAlpha) * smoothedBytesPerSecond
            }
        }
        previousBytesWritten = totalBytesWritten
        lastProgressReport = now

        let progress = DownloadProgress(
            bytesWritten: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            bytesPerSecond: smoothedBytesPerSecond
        )
        let handler = self.progressHandler
        Task { @MainActor in handler(progress) }
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
            Self.logger.error(
                "Failed to move IPSW from '\(location.path(percentEncoded: false), privacy: .public)' to '\(self.destinationURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
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
            // Propagate cancellation as CancellationError so callers can distinguish
            // user-initiated cancellation from genuine download failures.
            if let nsError = error as NSError?,
                nsError.domain == NSURLErrorDomain,
                nsError.code == NSURLErrorCancelled
            {
                // User/parent-task cancellation — drop any resume data so the next
                // attempt starts fresh. IPSWService.discardResumeData also runs on
                // the cancel path; this is belt-and-suspenders for the URLSession
                // side of the cancel race.
                removeSidecar(reason: "cancellation")
                Self.logger.info("Restore image download cancelled")
                continuation.resume(throwing: CancellationError())
            } else {
                // Network failure / sleep timeout / etc. — persist resume data so a
                // future attempt at the same destination can pick up where we left off.
                if let resumeData = (error as NSError?)?
                    .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                {
                    do {
                        try resumeData.write(to: sidecarURL, options: .atomic)
                        Self.logger.notice(
                            "Persisted IPSW resume data (\(resumeData.count, privacy: .public) bytes) to '\(self.sidecarURL.lastPathComponent, privacy: .public)'"
                        )
                    } catch {
                        Self.logger.warning(
                            "Failed to persist IPSW resume data at '\(self.sidecarURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    // Server returned a non-resumable error (404, 4xx, validator
                    // mismatch). Drop any stale sidecar so the next attempt is fresh.
                    removeSidecar(reason: "non-resumable error")
                }

                Self.logger.error("Restore image download failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: IPSWError.downloadFailed(error))
            }
        } else {
            // Successful completion — sidecar has served its purpose.
            removeSidecar(reason: "successful completion")

            let handler = self.progressHandler
            let progress = DownloadProgress(
                bytesWritten: max(0, task.countOfBytesReceived),
                totalBytes: max(0, task.countOfBytesExpectedToReceive),
                bytesPerSecond: 0
            )
            Task { @MainActor in handler(progress) }
            continuation.resume()
        }
    }

    private func removeSidecar(reason: String) {
        do {
            try FileManager.default.removeItem(at: sidecarURL)
        } catch CocoaError.fileNoSuchFile {
            // Common case — nothing to clean up.
        } catch {
            Self.logger.warning(
                "Failed to remove resume-data sidecar at '\(self.sidecarURL.path(percentEncoded: false), privacy: .public)' after \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
#endif

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL
    case downloadFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let underlyingError):
            "Failed to download restore image: \(underlyingError.localizedDescription)"
        }
    }
}
