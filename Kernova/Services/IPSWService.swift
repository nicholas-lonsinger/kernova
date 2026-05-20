import Foundation
import Virtualization
import os

/// Fetches and downloads macOS restore images (IPSWs) for macOS guest installation.
///
/// `final class` (rather than `struct`) so the `URLSession` we allocate in `init`
/// can be invalidated in `deinit`. Per Apple's docs, a session retains itself
/// until `finishTasksAndInvalidate()` or `invalidateAndCancel()` is called.
final class IPSWService: Sendable {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "IPSWService")

    #if arch(arm64)
    private let session: URLSession

    /// Designated initializer.
    ///
    /// Defaults to a per-instance default-configuration session; tests inject a
    /// configuration with stub `protocolClasses`.
    init(sessionConfiguration: URLSessionConfiguration? = nil) {
        let configuration = sessionConfiguration ?? .default
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
    #else
    init(sessionConfiguration: URLSessionConfiguration? = nil) {}
    #endif

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
    /// The partial download lives at `<destinationURL minus .ipsw>.kernovadownload/`,
    /// a Finder-visible bundle directory. The bundle's `data` file holds the
    /// partial bytes (file size IS the resume offset) and `Info.plist` holds
    /// the ETag / Last-Modified metadata used for `If-Range` resume. The
    /// expected total size is re-derived from each response's `Content-Length`
    /// or `Content-Range`, never cached.
    ///
    /// On user cancellation the bytes are preserved as-is (the file handle closes,
    /// the bundle stays put) and `CancellationError` is thrown so the non-destructive
    /// resume UX can pick up on the next Start. On any non-cancellation failure the
    /// bundle is also preserved for a future retry; only 4xx/5xx failures will reset
    /// state (the next attempt sends a fresh GET with no `Range` header).
    ///
    /// If the destination already contains a completed IPSW with no in-progress
    /// bundle next to it, the download is skipped entirely.
    func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        Self.logger.info("Downloading restore image from \(remoteURL, privacy: .public)")

        let bundleURL = Self.resumeBundleURL(for: destinationURL)
        let bundle = IPSWBundle(url: bundleURL)

        // Skip-existing fast path: a completed IPSW at the destination with no
        // in-progress bundle means a prior attempt already downloaded the file.
        // This happens when the user cancelled or hit an error during the install
        // phase (post-download). Skipping saves a multi-GB redownload and avoids
        // a "File exists" failure on the final move.
        if !bundle.exists,
            FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        {
            Self.logger.notice(
                "IPSW already present at '\(destinationURL.lastPathComponent, privacy: .public)' — skipping download"
            )
            let fileSize = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let completed = DownloadProgress(
                bytesWritten: Int64(fileSize),
                totalBytes: Int64(fileSize),
                bytesPerSecond: 0
            )
            // One-shot terminal callbacks use MainActor.run so the call is
            // ordered before our return — callers (and tests) can observe the
            // final progress synchronously after `await`. The streaming-loop
            // version intentionally uses Task fire-and-forget to avoid
            // back-pressuring the network read on every progress tick.
            await MainActor.run { progressHandler(completed) }
            return
        }

        // Resume metadata (if any) drives `Range` / `If-Range` header construction.
        // Helper handles three rejection cases (corrupt plist, URL mismatch,
        // non-https stored URL) by discarding the bundle and falling through to
        // a fresh download.
        let resumeMetadata = Self.loadResumeMetadata(
            bundleURL: bundleURL, bundle: bundle, remoteURL: remoteURL)

        let resumeOffset = resumeMetadata != nil ? bundle.partialByteCount : 0

        let (responseBytes, response) = try await performGET(
            url: remoteURL,
            resumeOffset: resumeMetadata != nil ? resumeOffset : nil,
            ifRangeETag: resumeMetadata?.etag,
            ifRangeLastModified: resumeMetadata?.lastModified
        )

        switch response.statusCode {
        case 200:
            // Fresh start (either initial download, or remote file changed during resume
            // and the server ignored our If-Range and sent the whole file).
            let metadata = IPSWDownloadMetadata(
                originalURL: remoteURL,
                etag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                createdAt: Date()
            )
            try bundle.prepareForFreshDownload(with: metadata)
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: 0,
                expectedTotal: response.expectedContentLength,
                progressHandler: progressHandler
            )

        case 206:
            // Partial Content — server honored our Range. The response's
            // Content-Range header is the authoritative source for the file's
            // total size (we no longer cache it in metadata). `response
            // .expectedContentLength` reports the partial-body length on 206,
            // not the full file, so we must parse Content-Range — fail-fast
            // when it's missing or malformed rather than substituting a wrong
            // total into the progress UI.
            guard resumeMetadata != nil else {
                // Server sent 206 without us asking; treat as a server error.
                Self.logger.error("Server returned 206 Partial Content without a Range request")
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            guard
                let rangeHeader = response.value(forHTTPHeaderField: "Content-Range"),
                let parsedRange = Self.parseContentRange(rangeHeader)
            else {
                Self.logger.error("206 response missing or unparseable Content-Range header")
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            if parsedRange.start != resumeOffset {
                Self.logger.warning(
                    "Content-Range start \(parsedRange.start, privacy: .public) ≠ requested offset \(resumeOffset, privacy: .public); trusting server"
                )
            }
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: resumeOffset,
                expectedTotal: parsedRange.total,
                progressHandler: progressHandler
            )

        case 416:
            // Range Not Satisfiable — usually means our `data` file is already
            // the full file, or the remote file shrank. The `Content-Range: bytes */N`
            // header tells us the actual total.
            let total = Self.parseUnsatisfiableTotal(
                response.value(forHTTPHeaderField: "Content-Range")
            )
            if let total, bundle.partialByteCount == total {
                Self.logger.notice("416 with full file already on disk — finalizing")
                try bundle.finalize(to: destinationURL)
                let progress = DownloadProgress(
                    bytesWritten: total, totalBytes: total, bytesPerSecond: 0)
                await MainActor.run { progressHandler(progress) }
                return
            }
            // Truncate and try one fresh GET in this same call. If that also fails
            // with non-2xx the throw below surfaces.
            Self.logger.warning("416 with no usable total or size mismatch — truncating and restarting")
            try bundle.truncateData()
            let (freshBytes, freshResponse) = try await performGET(
                url: remoteURL, resumeOffset: nil, ifRangeETag: nil, ifRangeLastModified: nil)
            guard freshResponse.statusCode == 200 else {
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            let metadata = IPSWDownloadMetadata(
                originalURL: remoteURL,
                etag: freshResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: freshResponse.value(forHTTPHeaderField: "Last-Modified"),
                createdAt: Date()
            )
            try bundle.saveMetadata(metadata)
            try await streamBytes(
                from: freshBytes,
                into: bundle,
                startingAt: 0,
                expectedTotal: freshResponse.expectedContentLength,
                progressHandler: progressHandler
            )

        default:
            Self.logger.error("Restore image GET returned HTTP \(response.statusCode, privacy: .public)")
            throw IPSWError.downloadFailed(URLError(.badServerResponse))
        }

        // Successful completion — move bytes to the user's chosen path and trash the bundle.
        // `streamBytes` already emitted the unthrottled final-progress callback,
        // so we don't need to do it here. (The previous version used
        // `response.expectedContentLength`, which on 206 reports the partial-body
        // length rather than the full file size — a bug now closed by relying on
        // `streamBytes`'s totalWritten.)
        try bundle.finalize(to: destinationURL)
        Self.logger.info(
            "Restore image downloaded to \(destinationURL.lastPathComponent, privacy: .public)"
        )
    }

    /// Loads bundle resume metadata and decides whether the bundle is usable.
    ///
    /// Discards (trashes via `removeItem` — the user has not implicitly
    /// authorized trashing here, only on explicit VM-delete via
    /// `discardResumeData`) and returns `nil` when:
    /// - the bundle directory exists but `Info.plist` can't be decoded;
    /// - the stored `originalURL` differs from the caller's `remoteURL`
    ///   (e.g. Apple shipped a new macOS build between attempts);
    /// - the stored `originalURL` has a non-https scheme (defends against a
    ///   tampered plist redirecting resume to `file://` or similar).
    private static func loadResumeMetadata(
        bundleURL: URL,
        bundle: IPSWBundle,
        remoteURL: URL
    ) -> IPSWDownloadMetadata? {
        guard bundle.exists else { return nil }

        let metadata: IPSWDownloadMetadata
        do {
            metadata = try bundle.loadMetadata()
        } catch {
            Self.logger.warning(
                "Bundle at '\(bundleURL.lastPathComponent, privacy: .public)' is corrupt — restarting download: \(error.localizedDescription, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            return nil
        }

        if metadata.originalURL != remoteURL {
            Self.logger.notice(
                "Bundle URL '\(metadata.originalURL, privacy: .public)' ≠ requested '\(remoteURL, privacy: .public)' — discarding stale bundle"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            return nil
        }

        guard metadata.originalURL.scheme?.lowercased() == "https" else {
            // Case-insensitive per RFC 3986 §3.1 ("the scheme component is
            // case-insensitive"). Apple's CDN always uses lowercase `https`,
            // but a tampered plist could try variants like `HTTPS://`.
            Self.logger.warning(
                "Stored bundle URL has non-https scheme '\(metadata.originalURL.scheme ?? "<nil>", privacy: .public)' — discarding"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            return nil
        }

        Self.logger.notice(
            "Resuming prior IPSW download from bundle at '\(bundleURL.lastPathComponent, privacy: .public)' (\(bundle.partialByteCount, privacy: .public) bytes on disk)"
        )
        return metadata
    }

    /// Trashes the `.kernovadownload` bundle for the given destination, if present.
    ///
    /// Safe to call when no bundle exists. The bundle may contain multi-GB of
    /// partial data; trashing (rather than `rm`) lets the user recover from Trash
    /// if a VM delete was unintentional. Mirrors the policy in commit `2ca723d`
    /// for external storage trashed on VM delete.
    func discardResumeData(at destinationURL: URL) {
        let bundleURL = Self.resumeBundleURL(for: destinationURL)
        do {
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
            Self.logger.info(
                "Trashed in-progress download bundle at '\(bundleURL.lastPathComponent, privacy: .public)'"
            )
        } catch CocoaError.fileNoSuchFile {
            // Nothing to discard — common case.
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // RATIONALE: Both catches are required. `CocoaError.fileNoSuchFile`
            // matches when FileManager throws a typed `CocoaError`, but
            // `trashItem(at:resultingItemURL:)` has been observed to surface
            // the same condition as a raw NSError(NSCocoaErrorDomain, ...) that
            // the first pattern doesn't catch. Removing either arm causes the
            // common "no bundle to trash" case to log noise.
        } catch {
            Self.logger.warning(
                "Failed to trash in-progress download bundle at '\(bundleURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the location of the in-progress `.kernovadownload` bundle for a
    /// given final-IPSW destination URL.
    ///
    /// Example: `~/Downloads/RestoreImage.ipsw` →
    /// `~/Downloads/RestoreImage.kernovadownload`.
    static func resumeBundleURL(for destinationURL: URL) -> URL {
        destinationURL.deletingPathExtension().appendingPathExtension("kernovadownload")
    }

    // MARK: - Helpers

    /// Issues a GET (with optional `Range` / `If-Range` headers) and returns the
    /// response plus a stream of `Data` chunks delivered by URLSession.
    ///
    /// Backed by a `URLSessionDataDelegate` rather than `URLSession.bytes(for:)`
    /// because the latter yields one byte at a time — fine for small payloads,
    /// catastrophic at the multi-GB scale of an IPSW (async overhead per byte
    /// dominates throughput).
    private func performGET(
        url: URL,
        resumeOffset: Int64?,
        ifRangeETag: String?,
        ifRangeLastModified: String?
    ) async throws -> (AsyncThrowingStream<Data, any Error>, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let resumeOffset, resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            if let etag = ifRangeETag {
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            } else if let lastModified = ifRangeLastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Range")
            }
        }

        let (stream, streamContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()

        let response = try await withCheckedThrowingContinuation {
            (responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>) in
            let delegate = StreamingDataTaskDelegate(
                responseContinuation: responseContinuation,
                streamContinuation: streamContinuation
            )
            let task = session.dataTask(with: request)
            // `URLSessionTask.delegate` is `weak`; the strong reference lives
            // in the `onTermination` capture below so the delegate stays alive
            // for the entire lifetime of the stream.
            task.delegate = delegate
            streamContinuation.onTermination = { _ in
                withExtendedLifetime(delegate) {}
                task.cancel()
            }
            task.resume()
        }
        return (stream, response)
    }

    private func streamBytes(
        from chunks: AsyncThrowingStream<Data, any Error>,
        into bundle: IPSWBundle,
        startingAt initialOffset: Int64,
        expectedTotal: Int64,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.seek(toOffset: UInt64(initialOffset))
        // RATIONALE: explicit close on success path so finalize() can move the file
        // (a still-open handle would block the move on some filesystems); the defer
        // is the cancellation/error safety net.
        var handleClosed = false
        defer {
            if !handleClosed { try? handle.close() }
        }

        var smoother = DownloadSpeedSmoother()
        var totalWritten = initialOffset

        // Initial progress emission so resume UX shows the correct starting
        // fraction immediately (e.g. 30% on a half-finished download), not a
        // delayed jump after the first chunk lands.
        await MainActor.run {
            progressHandler(
                DownloadProgress(
                    bytesWritten: totalWritten,
                    totalBytes: expectedTotal,
                    bytesPerSecond: 0
                )
            )
        }

        do {
            for try await data in chunks {
                // RATIONALE: `AsyncThrowingStream` from `makeStream()` doesn't
                // observe `Task.isCancelled` automatically between yields —
                // it just waits for the producer's next `yield`/`finish`. An
                // explicit check here lets `Task.cancel()` from a caller (e.g.
                // the user clicking Cancel) interrupt the stream promptly.
                try Task.checkCancellation()
                guard !data.isEmpty else { continue }
                try handle.write(contentsOf: data)
                totalWritten += Int64(data.count)
                Self.report(
                    bytesWritten: totalWritten,
                    expectedTotal: expectedTotal,
                    smoother: &smoother,
                    progressHandler: progressHandler
                )
            }
        } catch is CancellationError {
            Self.logger.info("Restore image download cancelled")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            Self.logger.info("Restore image download cancelled (URLError.cancelled)")
            throw CancellationError()
        } catch {
            Self.logger.error(
                "Restore image download failed mid-stream: \(error.localizedDescription, privacy: .public)"
            )
            throw IPSWError.downloadFailed(error)
        }

        try handle.close()
        handleClosed = true

        // Unthrottled final progress so callers see 100% (and the correct
        // total) even when the entire body arrives inside one throttle window
        // — common on fast networks or with stubbed/cached responses.
        await MainActor.run {
            progressHandler(
                DownloadProgress(
                    bytesWritten: totalWritten,
                    totalBytes: expectedTotal,
                    bytesPerSecond: 0
                )
            )
        }
    }

    private static func report(
        bytesWritten: Int64,
        expectedTotal: Int64,
        smoother: inout DownloadSpeedSmoother,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let bps = smoother.sample(totalBytes: bytesWritten, now: now) else { return }
        let progress = DownloadProgress(
            bytesWritten: bytesWritten,
            totalBytes: expectedTotal,
            bytesPerSecond: bps
        )
        Task { @MainActor in progressHandler(progress) }
    }

    /// Parses `Content-Range: bytes 0-499/1234` into `(0, 499, 1234)`.
    static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let withoutPrefix: String
        if trimmed.hasPrefix("bytes ") {
            withoutPrefix = String(trimmed.dropFirst("bytes ".count))
        } else {
            withoutPrefix = trimmed
        }
        let parts = withoutPrefix.components(separatedBy: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let rangeParts = parts[0].components(separatedBy: "-")
        guard rangeParts.count == 2,
            let start = Int64(rangeParts[0]),
            let end = Int64(rangeParts[1])
        else { return nil }
        return (start, end, total)
    }

    /// Parses the total-size field from a 416 `Content-Range: bytes */1234`.
    static func parseUnsatisfiableTotal(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let parts = header.components(separatedBy: "/")
        guard parts.count == 2 else { return nil }
        return Int64(parts[1].trimmingCharacters(in: .whitespaces))
    }
    #endif
}

// MARK: - IPSWProviding

extension IPSWService: IPSWProviding {}

// MARK: - Bundle Layout

#if arch(arm64)
/// Metadata serialized as `Info.plist` at the root of a `.kernovadownload` bundle.
///
/// Only fields the server doesn't tell us each request are persisted. The total
/// expected size is re-derived from `Content-Length` (200) or `Content-Range`
/// (206 / 416) on every request, so it's not cached here.
struct IPSWDownloadMetadata: Codable, Sendable, Equatable {
    var originalURL: URL
    var etag: String?
    var lastModified: String?
    var createdAt: Date
}

/// File-system helper for an in-progress IPSW download bundle.
///
/// Layout (mirrors Safari's `.download` package — files at the bundle root,
/// no `Contents/` subdirectory):
/// ```
/// <url>.kernovadownload/
///   Info.plist     ← IPSWDownloadMetadata
///   data           ← partial bytes; file size IS the resume offset
/// ```
///
/// The UTI registration in the app's `Info.plist` declares `.kernovadownload`
/// as a package conforming to `com.apple.package` so Finder renders the
/// directory as a single icon with Show Package Contents support.
struct IPSWBundle: Sendable {
    let url: URL

    var dataURL: URL { url.appendingPathComponent("data") }
    var infoPlistURL: URL { url.appendingPathComponent("Info.plist") }

    /// `true` when the bundle directory exists on disk (regardless of internal validity).
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    /// Current size of the `data` file on disk; the resume offset for the next request.
    var partialByteCount: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dataURL.path(percentEncoded: false))
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func loadMetadata() throws -> IPSWDownloadMetadata {
        let data = try Data(contentsOf: infoPlistURL)
        return try PropertyListDecoder().decode(IPSWDownloadMetadata.self, from: data)
    }

    func saveMetadata(_ metadata: IPSWDownloadMetadata) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(metadata)
        try data.write(to: infoPlistURL, options: .atomic)
    }

    /// Creates the bundle directory, ensures an empty `data` file, and writes `Info.plist`.
    ///
    /// Called on the fresh-download path (response 200) — if the bundle already exists,
    /// the data file is truncated to zero.
    ///
    /// Order matters for crash-safety: truncate first, write metadata last. A crash
    /// between truncate and metadata leaves stale metadata pointing at empty bytes
    /// — harmless, because resume sends `Range: bytes=0-` and the server either
    /// returns the matching old file (server-side ETag still valid) or 200 with the
    /// new file (server-side ETag changed), and our 200 branch then refreshes
    /// metadata to match. The reverse order would write new metadata pointing at
    /// stale bytes, which the next resume could not detect.
    func prepareForFreshDownload(with metadata: IPSWDownloadMetadata) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dataURL.path(percentEncoded: false)) {
            try truncateData()
        } else {
            FileManager.default.createFile(
                atPath: dataURL.path(percentEncoded: false), contents: nil)
        }
        try saveMetadata(metadata)
    }

    /// Truncates the `data` file to zero bytes (used when the remote file changed mid-resume).
    func truncateData() throws {
        let handle = try FileHandle(forWritingTo: dataURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }

    /// Moves the `data` file to the final IPSW destination and trashes the bundle.
    func finalize(to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: dataURL, to: destinationURL)
        try fm.trashItem(at: url, resultingItemURL: nil)
    }
}
#endif

// MARK: - URLSessionDataDelegate bridge

#if arch(arm64)
/// Bridges `URLSessionDataDelegate` callbacks to an `AsyncThrowingStream<Data, Error>`.
///
/// We don't use `URLSession.bytes(for:)` because its `AsyncBytes` yields one
/// byte at a time, which carries async-iteration overhead per byte. For a
/// multi-GB IPSW that's billions of iterations; the data-task delegate
/// delivers `Data` chunks (typically 4 KB–64 KB) which we write straight to
/// the bundle's data file with no intermediate buffering.
private final class StreamingDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // RATIONALE: URLSession serialises delegate callbacks onto a private queue,
    // so mutable state read/written only in those callbacks (and inside the
    // single-shot continuation resume) is race-free; `@unchecked Sendable` is
    // the standard idiom for this pattern.
    private let responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>
    private let streamContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var responseDelivered = false

    init(
        responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>,
        streamContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.responseContinuation = responseContinuation
        self.streamContinuation = streamContinuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !responseDelivered else {
            completionHandler(.allow)
            return
        }
        responseDelivered = true
        guard let httpResponse = response as? HTTPURLResponse else {
            responseContinuation.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        responseContinuation.resume(returning: httpResponse)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        streamContinuation.yield(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        if let error {
            // If the failure landed before any response delivery, surface it
            // through the response continuation so the awaiter sees the error
            // instead of hanging.
            if !responseDelivered {
                responseDelivered = true
                responseContinuation.resume(throwing: error)
            }
            streamContinuation.finish(throwing: error)
        } else {
            streamContinuation.finish()
        }
    }
}
#endif

// MARK: - Progress Smoothing

#if arch(arm64)
/// EWMA-smoothed download speed calculator with a minimum reporting interval.
///
/// Lifted from the previous `IPSWDownloadDelegate` so the streamed download
/// keeps the same progress-bar feel.
struct DownloadSpeedSmoother {
    /// EWMA smoothing factor — lower values produce smoother output.
    static let smoothingAlpha: Double = 0.2
    /// Minimum interval between progress reports.
    static let progressInterval: TimeInterval = 0.1

    private var lastReportTime: TimeInterval = 0
    private var previousBytes: Int64 = 0
    private var smoothed: Double = 0

    /// Records a byte count at the given time and returns the EWMA-smoothed
    /// bytes-per-second, or `nil` if the call is within the throttle window.
    mutating func sample(totalBytes: Int64, now: TimeInterval) -> Double? {
        guard now - lastReportTime >= Self.progressInterval else { return nil }
        if lastReportTime > 0 {
            let elapsed = now - lastReportTime
            let delta = Double(totalBytes - previousBytes)
            if elapsed > 0, delta >= 0 {
                let instant = delta / elapsed
                smoothed =
                    smoothed == 0
                    ? instant
                    : Self.smoothingAlpha * instant + (1 - Self.smoothingAlpha) * smoothed
            }
        }
        lastReportTime = now
        previousBytes = totalBytes
        return smoothed
    }
}
#endif

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL
    case downloadFailed(any Error)
    /// Surfaced when the "Download & Replace" intent could not be honored
    /// because the existing IPSW (or its in-progress bundle) could not be
    /// trashed — typically a permissions / read-only-volume problem the user
    /// needs to resolve before the new download can run.
    case freshDownloadCleanupFailed(path: String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let underlyingError):
            "Failed to download restore image: \(underlyingError.localizedDescription)"
        case .freshDownloadCleanupFailed(let path, let underlying):
            "Could not remove the existing file at \(path) before downloading the replacement: \(underlying.localizedDescription)"
        }
    }
}
