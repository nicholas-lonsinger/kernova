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

    // MARK: - Protocol Methods

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
            // All progress callbacks (one-shot terminal and mid-stream) use
            // `await MainActor.run` so the UI sees them in the order we
            // produced them. Unstructured `Task { @MainActor in ... }` would
            // not preserve enqueue order between samples.
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
            // Refuse to splice bytes when the server's start offset disagrees
            // with what we asked for — we'd write the body at the requested
            // offset, leaving the unrequested prefix bytes unchanged and the
            // file inconsistent. Trash the bundle so the next attempt restarts
            // from zero rather than re-resuming into a corrupt file.
            if parsedRange.start != resumeOffset {
                Self.logger.error(
                    "Content-Range start \(parsedRange.start, privacy: .public) ≠ requested offset \(resumeOffset, privacy: .public); discarding bundle"
                )
                try? FileManager.default.removeItem(at: bundleURL)
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: resumeOffset,
                expectedTotal: parsedRange.total,
                progressHandler: progressHandler
            )

        case 416:
            // Range Not Satisfiable. The happy case is "our `data` file is
            // already the full file" — finalize and return. Anything else
            // (size mismatch, missing or unparseable Content-Range) means the
            // remote file shrank or changed in a way our resume state can't
            // describe; trash the stale bundle and throw so the next Start
            // re-enters via the 200 path with no Range header.
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
            Self.logger.warning(
                "416 with no usable total or size mismatch — discarding bundle so the next attempt restarts from zero"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            throw IPSWError.downloadFailed(URLError(.badServerResponse))

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
    /// Returns `nil` (and discards the bundle via `removeItem`) when:
    /// - the bundle directory exists but `Info.plist` can't be decoded;
    /// - the stored `originalURL` differs from the caller's `remoteURL`
    ///   (e.g. Apple shipped a new macOS build between attempts).
    ///
    /// The URL-mismatch guard is sufficient defense against a tampered plist
    /// pointing at an attacker host: `remoteURL` originates from
    /// `VZMacOSRestoreImage.latestSupported`, which is always Apple's https
    /// CDN, so any non-Apple or non-https stored URL fails the equality check
    /// here.
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

        // Hoist the task out of the continuation closure so the cancellation
        // handler below can reach it. Otherwise a Task.cancel() landing while
        // we're awaiting the response would only stop the surrounding Swift
        // task — the URLSessionDataTask would keep waiting for headers until
        // the server replied or timed out, delaying user-visible cancellation.
        let task = session.dataTask(with: request)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                let delegate = StreamingDataTaskDelegate(
                    responseContinuation: responseContinuation,
                    streamContinuation: streamContinuation
                )
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
        } onCancel: {
            // Triggers the delegate's didCompleteWithError with URLError.cancelled,
            // which resumes the response continuation with a throw — so we don't
            // leak the continuation on cancellation.
            task.cancel()
        }
        return (stream, response)
    }

    /// Streams `chunks` into the bundle's `data` file.
    ///
    /// Seeks to `initialOffset` first, then emits progress callbacks as each
    /// chunk lands. Internal-visibility so the cancellation test can drive
    /// it without going through URLSession.
    func streamBytes(
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
                // Cancellation observed two ways. The in-loop check catches
                // cancels that arrive between yields with a pending chunk —
                // the iterator wakes, body runs, and we throw before writing.
                // The post-loop check below catches the harder case:
                // `AsyncThrowingStream`'s `next()` is wrapped in a
                // `withTaskCancellationHandler` that, on cancel, terminates
                // the storage and **resolves the pending `next()` with `nil`
                // instead of throwing**. That makes the for-await loop exit
                // *normally*, so without a check after the loop the function
                // would proceed to `finalize` with a partial file.
                try Task.checkCancellation()
                guard !data.isEmpty else { continue }
                try handle.write(contentsOf: data)
                totalWritten += Int64(data.count)
                if let progress = Self.nextProgressSample(
                    bytesWritten: totalWritten,
                    expectedTotal: expectedTotal,
                    smoother: &smoother
                ) {
                    await MainActor.run { progressHandler(progress) }
                }
            }
            // See the comment above: cancel while parked in `next()` returns
            // nil rather than throwing, so the loop exits cleanly. Re-check
            // here so the caller's catch can preserve the bundle for resume
            // rather than finalize partial bytes onto the user's destination.
            try Task.checkCancellation()
            // Defensive completeness check for the non-cancel "stream ended
            // before the body did" case — e.g. a server that closed the
            // connection cleanly under Content-Length, which `URLSession`
            // surfaces as `didCompleteWithError(nil)` rather than an error.
            // Without this, an incomplete file would also slip past finalize.
            // Throw a bare `URLError` so the generic `catch` below wraps it
            // *once* as `IPSWError.downloadFailed(URLError(...))` — throwing
            // a pre-wrapped IPSWError here would catch again and double-wrap.
            if expectedTotal > 0 && totalWritten < expectedTotal {
                throw URLError(.networkConnectionLost)
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

    /// Returns the next `DownloadProgress` sample, or `nil` if throttled.
    ///
    /// The caller awaits the MainActor hop so progress callbacks land in
    /// order — fire-and-forget `Task` would not preserve enqueue order.
    private static func nextProgressSample(
        bytesWritten: Int64,
        expectedTotal: Int64,
        smoother: inout DownloadSpeedSmoother
    ) -> DownloadProgress? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let bps = smoother.sample(totalBytes: bytesWritten, now: now) else { return nil }
        return DownloadProgress(
            bytesWritten: bytesWritten,
            totalBytes: expectedTotal,
            bytesPerSecond: bps
        )
    }

    /// Parses `Content-Range: bytes 0-499/1234` into `(0, 499, 1234)`.
    ///
    /// Permissive on whitespace (`bytes 0 - 499 / 1234` works) since real-world
    /// proxies sometimes insert it; the `(?:bytes\s+)?` unit prefix is also
    /// optional. `\d+` rejects signed totals like `*/-5`, which the old
    /// `Int64()`-parse would have accepted.
    static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64)? {
        let pattern = #/^\s*(?:bytes\s+)?(\d+)\s*-\s*(\d+)\s*/\s*(\d+)\s*$/#
        guard let match = try? pattern.wholeMatch(in: header),
            let start = Int64(match.output.1),
            let end = Int64(match.output.2),
            let total = Int64(match.output.3)
        else { return nil }
        return (start, end, total)
    }

    /// Parses the total-size field from a 416 `Content-Range: bytes */1234`.
    static func parseUnsatisfiableTotal(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let pattern = #/^\s*(?:bytes\s+)?\*\s*/\s*(\d+)\s*$/#
        guard let match = try? pattern.wholeMatch(in: header),
            let total = Int64(match.output.1)
        else { return nil }
        return total
    }
}

// MARK: - IPSWProviding

extension IPSWService: IPSWProviding {}

// MARK: - Bundle Layout

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

// MARK: - URLSessionDataDelegate bridge

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

// MARK: - Progress Smoothing

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

// MARK: - Errors

enum IPSWError: LocalizedError {
    case noDownloadURL
    case downloadFailed(any Error)
    /// Surfaced when the "Download & Replace" intent could not be honored
    /// because the existing IPSW (or its in-progress bundle) could not be
    /// trashed — typically a permissions / read-only-volume problem the user
    /// needs to resolve before the new download can run.
    case freshDownloadCleanupFailed(path: String, underlying: any Error)
    /// Surfaced when `downloadDestinationPath` from the install context does
    /// not name an `.ipsw` file. Guards against acting on a path that was
    /// corrupted or hand-edited in `config.json` between sessions.
    case invalidDownloadDestination(path: String)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let underlyingError):
            "Failed to download restore image: \(underlyingError.localizedDescription)"
        case .freshDownloadCleanupFailed(let path, let underlying):
            "Could not remove the existing file at \(path) before downloading the replacement: \(underlying.localizedDescription)"
        case .invalidDownloadDestination(let path):
            "Cannot download to '\(path)' — destination must be a .ipsw file."
        }
    }
}
