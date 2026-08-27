import Foundation
import os

/// Streams a remote file to a local destination, resuming an interrupted
/// transfer from the partial bytes left beside it.
///
/// A class rather than a struct so `deinit` can invalidate the `URLSession`: per
/// Apple's docs a session retains itself until `finishTasksAndInvalidate()` or
/// `invalidateAndCancel()` is called.
final class DownloadService: Sendable {
    private static let logger = Logger(subsystem: "app.kernova", category: "DownloadService")

    private let session: URLSession
    private let fileSystem: any FileSystemOperating

    init(
        sessionConfiguration: URLSessionConfiguration? = nil,
        fileSystem: any FileSystemOperating = FileManager.default
    ) {
        let configuration = sessionConfiguration ?? .default
        self.session = URLSession(configuration: configuration)
        self.fileSystem = fileSystem
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Downloading

    /// Downloads a file from a remote URL to the specified destination.
    ///
    /// The partial download lives at `<destinationURL minus its extension>.kernovadownload/`;
    /// its `data` file size IS the resume offset, and `Info.plist` holds the
    /// ETag / Last-Modified used for `If-Range`. The bundle survives a failure
    /// a later attempt can resume past, cancellation included (which throws
    /// `CancellationError`); one it cannot — a response disagreeing with the
    /// bytes already on disk, or a source larger than `expectedSizeBytes` —
    /// discards the bundle so the next attempt restarts from zero. A completed
    /// file with no bundle beside it is skipped.
    ///
    /// Calls are serialized per destination: two callers pinned to the same
    /// remote file share one path and one bundle, so a second caller waits for
    /// the download already streaming there and then skips over the file it
    /// finished.
    ///
    /// `discardsExistingDownload` honors a "Download & Replace": the file and
    /// bundle at the destination are trashed first, inside the claim, so the
    /// disposal cannot reach bytes another caller is streaming into them.
    ///
    /// `expectedSizeBytes` caps the bytes that may land on disk, the resumed
    /// ones included: a source serving an unbounded body — chunked, with no
    /// `Content-Length` to check the stream against — is stopped at the ceiling
    /// with ``DownloadError/oversizedTransfer(expectedBytes:)`` rather than
    /// filling the volume. `nil` leaves the transfer unbounded.
    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool = false,
        expectedSizeBytes: UInt64? = nil,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let key = destinationURL.standardizedFileURL.path(percentEncoded: false)
        var discardsExisting = discardsExistingDownload
        while true {
            try Task.checkCancellation()
            let discards = discardsExisting
            let claim = await Self.claimDownload(forKey: key) { [self] in
                try await performDownload(
                    from: remoteURL, to: destinationURL, discardsExistingDownload: discards,
                    expectedSizeBytes: expectedSizeBytes,
                    progressHandler: progressHandler)
            }
            guard claim.isOwner else {
                Self.logger.notice(
                    "A download to '\(destinationURL.lastPathComponent, privacy: .public)' is already running — waiting for it to finish"
                )
                // That download's failure is its own caller's to report; this one
                // loops and downloads, resuming from whatever bytes landed. What
                // it landed is this call's file too — same destination, same
                // pinned URL — so there is nothing stale left to replace.
                _ = try? await claim.task.value
                discardsExisting = false
                continue
            }
            try await withTaskCancellationHandler {
                try await claim.task.value
            } onCancel: {
                claim.task.cancel()
            }
            return
        }
    }

    /// Runs one download, with this destination already reserved by the caller.
    private func performDownload(
        from remoteURL: URL,
        to destinationURL: URL,
        discardsExistingDownload: Bool,
        expectedSizeBytes: UInt64?,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        Self.logger.info("Downloading from \(Self.loggableURL(remoteURL), privacy: .public)")

        if discardsExistingDownload {
            try discardExistingFile(at: destinationURL)
        }

        let bundleURL = Self.resumeBundleURL(for: destinationURL)
        let bundle = DownloadBundle(url: bundleURL)

        // A completed file with no resumable bundle means a prior attempt
        // already downloaded it and failed later, in whatever step consumes it.
        // The guard is `isResumable`, not `exists`: a husk left by a finalize
        // whose disposal failed has no bytes to resume from and must not force a
        // re-download of a file already sitting complete at the destination.
        if !bundle.isResumable,
            FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        {
            Self.logger.notice(
                "File already present at '\(destinationURL.lastPathComponent, privacy: .public)' — skipping download"
            )
            if bundle.exists {
                discardResumeData(at: destinationURL)
            }
            let fileSize = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let completed = DownloadProgress(
                bytesWritten: Int64(fileSize),
                totalBytes: Int64(fileSize),
                bytesPerSecond: 0
            )
            // `await MainActor.run`, not `Task { @MainActor in … }`: only awaiting
            // delivers progress samples in the order they were produced.
            await MainActor.run { progressHandler(completed) }
            return
        }

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
            let metadata = DownloadBundleMetadata(
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
                expectedSizeBytes: expectedSizeBytes,
                progressHandler: progressHandler
            )

        case 206:
            // `response.expectedContentLength` reports the partial-body length on
            // a 206, not the full file, so the total has to come from
            // Content-Range — fail fast rather than feed the progress UI a wrong
            // total.
            guard resumeMetadata != nil else {
                // Server sent 206 without us asking; treat as a server error.
                Self.logger.error("Server returned 206 Partial Content without a Range request")
                throw DownloadError.downloadFailed(URLError(.badServerResponse))
            }
            guard
                let rangeHeader = response.value(forHTTPHeaderField: "Content-Range"),
                let parsedRange = Self.parseContentRange(rangeHeader)
            else {
                Self.logger.error("206 response missing or unparseable Content-Range header")
                throw DownloadError.downloadFailed(URLError(.badServerResponse))
            }
            // Splicing at the requested offset when the server started somewhere
            // else leaves the intervening bytes stale and the file silently
            // corrupt. Trash the bundle so the next attempt restarts from zero.
            if parsedRange.start != resumeOffset {
                Self.logger.error(
                    "Content-Range start \(parsedRange.start, privacy: .public) ≠ requested offset \(resumeOffset, privacy: .public); discarding bundle"
                )
                try? FileManager.default.removeItem(at: bundleURL)
                throw DownloadError.downloadFailed(URLError(.badServerResponse))
            }
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: resumeOffset,
                expectedTotal: parsedRange.total,
                expectedSizeBytes: expectedSizeBytes,
                progressHandler: progressHandler
            )

        case 416:
            // Range Not Satisfiable. Only "our `data` file is already the full
            // file" is recoverable; anything else means the remote file changed
            // in a way the resume state can't describe, so trash the bundle and
            // throw — the next Start re-enters via the 200 path with no Range.
            let total = Self.parseUnsatisfiableTotal(
                response.value(forHTTPHeaderField: "Content-Range")
            )
            if let total, bundle.partialByteCount == total {
                Self.logger.notice("416 with full file already on disk — finalizing")
                try bundle.finalize(to: destinationURL)
                discardResumeData(at: destinationURL)
                let progress = DownloadProgress(
                    bytesWritten: total, totalBytes: total, bytesPerSecond: 0)
                await MainActor.run { progressHandler(progress) }
                return
            }
            Self.logger.warning(
                "416 with no usable total or size mismatch — discarding bundle so the next attempt restarts from zero"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            throw DownloadError.downloadFailed(URLError(.badServerResponse))

        default:
            Self.logger.error("Download GET returned HTTP \(response.statusCode, privacy: .public)")
            throw DownloadError.downloadFailed(URLError(.badServerResponse))
        }

        // `streamBytes` already emitted the unthrottled final-progress callback.
        try bundle.finalize(to: destinationURL)
        discardResumeData(at: destinationURL)
        Self.logger.info("Downloaded to \(destinationURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Adopting a File Already on Disk

    /// Places the file at `sourceURL` at `destinationURL` as a hard link, so a
    /// caller that has already established the file is the one it would fetch
    /// spends no bytes fetching it again.
    ///
    /// A link rather than a move or a copy: the entry at `sourceURL` stays the
    /// user's, no multi-gigabyte second copy lands on the volume, and the
    /// destination is a path of its own that keeps working when the user later
    /// disposes of theirs. Both paths must be on one volume, which they are —
    /// each is inside Downloads.
    ///
    /// Runs under the same per-destination claim ``download(from:to:discardsExistingDownload:expectedSizeBytes:progressHandler:)``
    /// takes, so a transfer already streaming to `destinationURL` is never
    /// linked over: that case answers `false` at once rather than waiting, and
    /// the caller downloads. `false` also when the destination is occupied or
    /// the link is refused. The file at `sourceURL` is never written to.
    func adoptExistingFile(at sourceURL: URL, as destinationURL: URL) async -> Bool {
        let key = destinationURL.standardizedFileURL.path(percentEncoded: false)
        let claim = await Self.claimDownload(forKey: key) { [self] in
            try performAdoption(of: sourceURL, as: destinationURL)
        }
        guard claim.isOwner else {
            Self.logger.notice(
                "A download to '\(destinationURL.lastPathComponent, privacy: .public)' is already running — downloading rather than adopting"
            )
            return false
        }
        do {
            try await claim.task.value
            return true
        } catch {
            return false
        }
    }

    /// Runs one adoption, with this destination already reserved by the caller.
    ///
    /// Throwing is how a refusal reaches ``adoptExistingFile(at:as:)``; each
    /// reason is logged here, where what happened is known.
    private func performAdoption(of sourceURL: URL, as destinationURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
        else {
            Self.logger.notice(
                "'\(destinationURL.lastPathComponent, privacy: .public)' is already on disk — downloading rather than adopting"
            )
            throw AdoptionRefusal.destinationOccupied
        }
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            Self.logger.warning(
                "Failed to link '\(sourceURL.lastPathComponent, privacy: .public)' to '\(destinationURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        Self.logger.notice(
            "Adopted '\(sourceURL.lastPathComponent, privacy: .public)' as '\(destinationURL.lastPathComponent, privacy: .public)' — no bytes moved"
        )
        // Whatever a prior attempt left part-way through is superseded by a
        // complete file, and it can run to gigabytes.
        discardResumeData(at: destinationURL, permanently: false)
    }

    /// Why an adoption did not happen. Never reaches a caller — ``adoptExistingFile(at:as:)``
    /// answers `false` for every refusal, this one included.
    private enum AdoptionRefusal: Error {
        case destinationOccupied
    }

    /// Loads bundle resume metadata and decides whether the bundle is usable.
    ///
    /// Returns `nil` when the bundle holds no partial bytes to resume from, and
    /// `nil` after discarding the bundle when `Info.plist` can't be decoded or
    /// its stored `originalURL` differs from `remoteURL` (the publisher moved
    /// the file between attempts).
    private static func loadResumeMetadata(
        bundleURL: URL,
        bundle: DownloadBundle,
        remoteURL: URL
    ) -> DownloadBundleMetadata? {
        // `isResumable`, not `exists`: a husk decodes valid metadata with no bytes
        // behind it, logging a false "Resuming…" before restarting anyway.
        guard bundle.isResumable else { return nil }

        let metadata: DownloadBundleMetadata
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
                "Bundle URL '\(Self.loggableURL(metadata.originalURL), privacy: .public)' ≠ requested '\(Self.loggableURL(remoteURL), privacy: .public)' — discarding stale bundle"
            )
            try? FileManager.default.removeItem(at: bundleURL)
            return nil
        }

        Self.logger.notice(
            "Resuming prior download from bundle at '\(bundleURL.lastPathComponent, privacy: .public)' (\(bundle.partialByteCount, privacy: .public) bytes on disk)"
        )
        return metadata
    }

    /// Trashes the file at `destinationURL` and any partial bundle beside it.
    ///
    /// Trashing the completed file is a hard failure: the skip-existing fast
    /// path would otherwise hand back the very file the caller asked to replace.
    /// Losing the partial bundle is not — it goes to the Trash on a best-effort
    /// basis, restorable by the user either way.
    private func discardExistingFile(at destinationURL: URL) throws {
        let path = destinationURL.path(percentEncoded: false)
        if fileSystem.fileExists(atPath: path) {
            do {
                try fileSystem.trashItem(at: destinationURL)
            } catch {
                Self.logger.error(
                    "Failed to trash the existing file at '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                throw DownloadError.freshDownloadCleanupFailed(path: path, underlying: error)
            }
            Self.logger.notice(
                "Trashed the existing file at '\(destinationURL.lastPathComponent, privacy: .public)' for a fresh download"
            )
        }
        discardResumeData(at: destinationURL)
    }

    /// Discards the `.kernovadownload` bundle for the given destination, if present.
    ///
    /// Safe to call when no bundle exists, and non-fatal by design — every failure
    /// is swallowed and logged, which is what lets callers treat disposal as
    /// cleanup rather than part of the download's success condition.
    ///
    /// Trashes by default so a multi-GB partial survives an unintended VM delete;
    /// `permanently` removes it outright, matching a "Delete Immediately" delete.
    func discardResumeData(at destinationURL: URL, permanently: Bool = false) {
        let bundleURL = Self.resumeBundleURL(for: destinationURL)
        do {
            if permanently {
                try fileSystem.removeItem(at: bundleURL)
            } else {
                try fileSystem.trashItem(at: bundleURL)
            }
            Self.logger.info(
                "Discarded in-progress download bundle at '\(bundleURL.lastPathComponent, privacy: .public)'"
            )
        } catch CocoaError.fileNoSuchFile {
            // Nothing to discard — common case.
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Both arms are required: `trashItem` surfaces "no such file" as a
            // raw `NSError(NSCocoaErrorDomain, NSFileNoSuchFileError)` that the
            // typed `CocoaError.fileNoSuchFile` pattern above does not catch.
        } catch {
            Self.logger.warning(
                "Failed to discard in-progress download bundle at '\(bundleURL.path(percentEncoded: false), privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Location of the in-progress `.kernovadownload` bundle for a final destination.
    static func resumeBundleURL(for destinationURL: URL) -> URL {
        destinationURL.deletingPathExtension().appendingPathExtension("kernovadownload")
    }

    // MARK: - Destination Serialization

    /// Downloads currently streaming, keyed by standardized destination path.
    ///
    /// A destination's `.kernovadownload` bundle takes one writer at a time: the
    /// truncate / append / move sequence produces a corrupt file when two
    /// downloads to the same path interleave. Keyed by path rather than held per
    /// instance because the contended resource is the file, not the service —
    /// which is also what keeps two *different* download pipelines from racing
    /// one destination.
    @MainActor private static var inFlightDownloads: [String: Task<Void, any Error>] = [:]

    /// Hands back the download already streaming to `key`, or starts `operation`
    /// as the one that owns it.
    ///
    /// Synchronous on the MainActor, so no second caller can look up an empty
    /// slot and fill it in between. The task clears its own slot before it
    /// finishes, so a waiter that sees it complete finds the slot free.
    @MainActor
    private static func claimDownload(
        forKey key: String,
        operation: @Sendable @escaping () async throws -> Void
    ) -> (task: Task<Void, any Error>, isOwner: Bool) {
        if let existing = inFlightDownloads[key] { return (existing, false) }
        let task = Task<Void, any Error> {
            defer { inFlightDownloads[key] = nil }
            try await operation()
        }
        inFlightDownloads[key] = task
        return (task, true)
    }

    // MARK: - Helpers

    /// Renders a remote URL for logging as scheme, host, port and path only.
    ///
    /// A user-supplied download URL can carry pre-signed credentials in its
    /// query or userinfo (S3 and CloudFront signatures), which the unified log
    /// would otherwise persist.
    static func loggableURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.lastPathComponent
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.lastPathComponent
    }

    /// Issues a GET (with optional `Range` / `If-Range` headers) and returns the
    /// response plus a stream of `Data` chunks delivered by URLSession.
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

        // The task must be hoisted out of the continuation closure so the
        // cancellation handler can reach it; otherwise a cancel that lands while
        // we await the response leaves the URLSessionDataTask waiting for headers
        // until the server replies or times out.
        let task = session.dataTask(with: request)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                let delegate = StreamingDataTaskDelegate(
                    responseContinuation: responseContinuation,
                    streamContinuation: streamContinuation
                )
                // `URLSessionTask.delegate` is `weak`; the strong reference lives
                // in the `onTermination` capture below, which is what keeps the
                // delegate alive for the lifetime of the stream.
                task.delegate = delegate
                streamContinuation.onTermination = { _ in
                    withExtendedLifetime(delegate) {}
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            // Triggers the delegate's didCompleteWithError with URLError.cancelled,
            // which resumes the response continuation with a throw rather than
            // leaking it.
            task.cancel()
        }
        return (stream, response)
    }

    /// Streams `chunks` into the bundle's `data` file, seeking to `initialOffset` first.
    ///
    /// `expectedSizeBytes` bounds the file the caller is willing to land:
    /// `initialOffset` plus everything written is held under it, so a resumed
    /// transfer spends the same budget the first attempt did. A source stating
    /// a total over the ceiling is stopped before its body moves; one stating
    /// no total at all — chunked, the shape the ceiling exists for — is stopped
    /// at the chunk that would cross it. Either way the bundle goes, because a
    /// source serving more than the ceiling allows leaves no offset a resume
    /// could finish from.
    func streamBytes(
        from chunks: AsyncThrowingStream<Data, any Error>,
        into bundle: DownloadBundle,
        startingAt initialOffset: Int64,
        expectedTotal: Int64,
        expectedSizeBytes: UInt64?,
        progressHandler: @MainActor @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.seek(toOffset: UInt64(initialOffset))
        // Explicit close on the success path so `finalize` can move the file — a
        // still-open handle blocks the move on some filesystems. The defer is the
        // cancellation/error safety net.
        var handleClosed = false
        defer {
            if !handleClosed { try? handle.close() }
        }

        var smoother = DownloadSpeedSmoother()
        var totalWritten = initialOffset

        // A stated total over the ceiling can't fit however its body arrives, so
        // stop here rather than move the whole ceiling first and abort on the
        // chunk that crosses it — every Start would spend the transfer again.
        if let ceiling = expectedSizeBytes, expectedTotal > 0,
            UInt64(clamping: expectedTotal) > ceiling
        {
            Self.logger.error(
                "Source states \(expectedTotal, privacy: .public) bytes against an expected \(ceiling, privacy: .public) — stopping before its body moves"
            )
            Self.emptyAndDiscard(bundle, dataHandle: handle)
            handleClosed = true
            throw DownloadError.oversizedTransfer(expectedBytes: ceiling)
        }

        // Emit up front so a resumed download shows its true starting fraction
        // immediately instead of jumping after the first chunk lands.
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
                // Both this check and the one after the loop are required. A
                // cancel while parked in `AsyncThrowingStream.next()` resolves
                // the pending element with `nil` instead of throwing, so the
                // for-await loop exits *normally* and a partial file would reach
                // `finalize`. This check covers the other case: a cancel that
                // arrives with a chunk already pending.
                try Task.checkCancellation()
                guard !data.isEmpty else { continue }
                // Checked before the write, so nothing past the ceiling ever
                // reaches the volume.
                if let ceiling = expectedSizeBytes,
                    UInt64(clamping: totalWritten) + UInt64(data.count) > ceiling
                {
                    Self.logger.error(
                        "Transfer ran past its expected \(ceiling, privacy: .public) bytes — stopping"
                    )
                    Self.emptyAndDiscard(bundle, dataHandle: handle)
                    handleClosed = true
                    throw DownloadError.oversizedTransfer(expectedBytes: ceiling)
                }
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
            // Cancel while parked in `next()` exits the loop normally (see above).
            try Task.checkCancellation()
            // A server that closes the connection cleanly under Content-Length
            // surfaces as `didCompleteWithError(nil)`, so an incomplete file
            // would otherwise slip past `finalize` too. Throw a bare `URLError`:
            // a pre-wrapped `DownloadError` would be caught below and double-wrapped.
            if expectedTotal > 0 && totalWritten < expectedTotal {
                throw URLError(.networkConnectionLost)
            }
        } catch is CancellationError {
            Self.logger.info("Download cancelled")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            Self.logger.info("Download cancelled (URLError.cancelled)")
            throw CancellationError()
        } catch let downloadError as DownloadError {
            // Raised by this method, already carrying the message the user
            // sees; `.downloadFailed` would bury it one level down.
            throw downloadError
        } catch {
            Self.logger.error(
                "Download failed mid-stream: \(error.localizedDescription, privacy: .public)"
            )
            throw DownloadError.downloadFailed(error)
        }

        try handle.close()
        handleClosed = true

        // Unthrottled, so callers still see 100% when the whole body arrives
        // inside a single throttle window.
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

    /// Empties the bundle's `data` file through the open handle, closes the
    /// handle, then removes the bundle.
    ///
    /// The handle is spent when this returns, whichever steps succeeded.
    ///
    /// Three steps because only the first is certain. Removal can be refused —
    /// permissions, or a volume that won't unlink an open file — and a bundle
    /// that survives holding zero bytes still resumes from offset 0, which
    /// sends the next attempt out with no `Range` header. Closing first is what
    /// gives the removal its best chance on the volumes that refuse.
    ///
    /// Removed rather than trashed, unlike `discardResumeData`: these bytes can
    /// never complete this download, so each Start the user pressed would
    /// otherwise deposit another multi-GB copy in the Trash.
    private static func emptyAndDiscard(_ bundle: DownloadBundle, dataHandle: FileHandle) {
        do {
            try dataHandle.truncate(atOffset: 0)
        } catch {
            Self.logger.warning(
                "Failed to empty the partial data in '\(bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        try? dataHandle.close()
        do {
            try FileManager.default.removeItem(at: bundle.url)
            Self.logger.notice(
                "Discarded the bundle at '\(bundle.url.lastPathComponent, privacy: .public)' — the next attempt restarts from zero"
            )
        } catch {
            Self.logger.warning(
                "Failed to remove the bundle at '\(bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the next `DownloadProgress` sample, or `nil` if throttled.
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
    /// proxies sometimes insert it; the unit prefix is optional too.
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

// MARK: - Downloading

extension DownloadService: Downloading {}

// MARK: - Bundle Layout

/// Metadata serialized as `Info.plist` at the root of a `.kernovadownload` bundle.
///
/// The expected total size is deliberately absent — it is re-derived from
/// `Content-Length` (200) or `Content-Range` (206 / 416) on every request.
struct DownloadBundleMetadata: Codable, Sendable, Equatable {
    var originalURL: URL
    var etag: String?
    var lastModified: String?
    var createdAt: Date
}

/// File-system helper for an in-progress download bundle.
///
/// Layout mirrors Safari's `.download` package — files at the bundle root, no
/// `Contents/`: `Info.plist` (`DownloadBundleMetadata`) and `data`, whose file
/// size IS the resume offset. The app's `Info.plist` declares `.kernovadownload`
/// as a package conforming to `com.apple.package`, so Finder renders the
/// directory as a single icon.
struct DownloadBundle: Sendable {
    let url: URL

    var dataURL: URL { url.appendingPathComponent("data") }
    var infoPlistURL: URL { url.appendingPathComponent("Info.plist") }

    /// `true` when the bundle directory exists on disk (regardless of internal validity).
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    /// `true` when the bundle directory exists *and* still holds its `data` file.
    ///
    /// A `finalize` whose disposal failed leaves a husk — `data` moved to the
    /// destination, `Info.plist` still present — that passes `exists` and decodes
    /// valid metadata but has no bytes to resume from. Every resume decision must
    /// ask this, not `exists`.
    var isResumable: Bool {
        exists
            && FileManager.default.fileExists(atPath: dataURL.path(percentEncoded: false))
    }

    /// Current size of the `data` file on disk; the resume offset for the next request.
    var partialByteCount: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dataURL.path(percentEncoded: false))
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func loadMetadata() throws -> DownloadBundleMetadata {
        let data = try Data(contentsOf: infoPlistURL)
        return try PropertyListDecoder().decode(DownloadBundleMetadata.self, from: data)
    }

    func saveMetadata(_ metadata: DownloadBundleMetadata) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(metadata)
        try data.write(to: infoPlistURL, options: .atomic)
    }

    /// Creates the bundle directory, ensures an empty `data` file, and writes `Info.plist`.
    ///
    /// Order matters for crash-safety: truncate first, write metadata last. Stale
    /// metadata over empty bytes is harmless (resume sends `Range: bytes=0-`, and
    /// the 200 branch refreshes it); new metadata over stale bytes is undetectable.
    func prepareForFreshDownload(with metadata: DownloadBundleMetadata) throws {
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

    /// Truncates the `data` file to zero bytes.
    func truncateData() throws {
        let handle = try FileHandle(forWritingTo: dataURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }

    /// Moves the `data` file to the final destination.
    ///
    /// Disposing of the spent bundle is not part of this step — callers follow up
    /// with `DownloadService.discardResumeData(at:)`, so a disposal failure can't
    /// undo a download whose bytes are already in place.
    func finalize(to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: dataURL, to: destinationURL)
    }
}

// MARK: - URLSessionDataDelegate bridge

/// Bridges `URLSessionDataDelegate` callbacks to an `AsyncThrowingStream<Data, Error>`.
///
/// `URLSession.bytes(for:)` is unusable here: its `AsyncBytes` yields one byte at
/// a time, which for a multi-GB image is billions of async iterations. The
/// data-task delegate delivers `Data` chunks instead, written straight to the
/// bundle's data file with no intermediate buffering.
private final class StreamingDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // URLSession serialises delegate callbacks onto a private queue, so the
    // mutable state below — touched only in those callbacks — is race-free.
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
            // A failure landing before response delivery must go out through the
            // response continuation, or the awaiter hangs.
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
struct DownloadSpeedSmoother {
    /// EWMA smoothing factor — lower values produce smoother output.
    ///
    /// The filter is sample-indexed, so its effective window is roughly
    /// `((1 - alpha) / alpha)` samples: at 0.02 and the 0.1 s reporting interval
    /// below, ~5 s of transfer.
    static let smoothingAlpha: Double = 0.02
    /// Minimum interval between progress reports (paces the progress bar).
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

enum DownloadError: LocalizedError {
    case downloadFailed(any Error)
    /// The existing file (or its in-progress bundle) could not be trashed to
    /// make way for a "Download & Replace".
    case freshDownloadCleanupFailed(path: String, underlying: any Error)
    /// The requested destination does not name a file of the expected type.
    case invalidDownloadDestination(path: String)
    /// The downloaded file's SHA-256 differs from the digest served beside it.
    case checksumMismatch(filename: String, expected: String, actual: String)
    /// The transfer ran past the size the source stated for it.
    case oversizedTransfer(expectedBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let underlyingError):
            "The download failed: \(underlyingError.localizedDescription)"
        case .freshDownloadCleanupFailed(let path, let underlying):
            "Could not remove the existing file at \(path) before downloading the replacement: \(underlying.localizedDescription)"
        case .invalidDownloadDestination(let path):
            "Cannot download to '\(path)' — the destination is not a supported file type."
        case .checksumMismatch(let filename, _, _):
            "\(filename) doesn't match the checksum listed alongside it. Try downloading it again."
        case .oversizedTransfer(let expectedBytes):
            "The download exceeded its expected size of \(DataFormatters.formatBytes(expectedBytes)) and was stopped."
        }
    }
}
