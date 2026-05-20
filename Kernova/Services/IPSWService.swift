import Foundation
import Virtualization
import os

/// Fetches and downloads macOS restore images (IPSWs) for macOS guest installation.
struct IPSWService: Sendable {
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
    /// a Finder-visible bundle directory. `Contents/data` holds the partial bytes (file
    /// size IS the resume offset) and `Contents/Info.plist` holds the ETag /
    /// Last-Modified / expected-size metadata used for `If-Range` resume.
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
            await MainActor.run { progressHandler(completed) }
            return
        }

        // Resume metadata (if any) drives `Range` / `If-Range` header construction.
        // A bundle that fails to load metadata is treated as corrupt — trashed so
        // the request below falls through to the fresh-download branch.
        let resumeMetadata: IPSWDownloadMetadata?
        if bundle.exists {
            do {
                resumeMetadata = try bundle.loadMetadata()
                Self.logger.notice(
                    "Resuming prior IPSW download from bundle at '\(bundleURL.lastPathComponent, privacy: .public)' (\(bundle.partialByteCount, privacy: .public) bytes on disk)"
                )
            } catch {
                Self.logger.warning(
                    "Bundle at '\(bundleURL.lastPathComponent, privacy: .public)' is corrupt — restarting download: \(error.localizedDescription, privacy: .public)"
                )
                try? FileManager.default.removeItem(at: bundleURL)
                resumeMetadata = nil
            }
        } else {
            resumeMetadata = nil
        }

        let resumeOffset = resumeMetadata != nil ? bundle.partialByteCount : 0
        let sourceURL = resumeMetadata?.originalURL ?? remoteURL

        let (responseBytes, response) = try await performGET(
            url: sourceURL,
            resumeOffset: resumeMetadata != nil ? resumeOffset : nil,
            ifRangeETag: resumeMetadata?.etag,
            ifRangeLastModified: resumeMetadata?.lastModified
        )

        switch response.statusCode {
        case 200:
            // Fresh start (either initial download, or remote file changed during resume
            // and the server ignored our If-Range and sent the whole file).
            let metadata = IPSWDownloadMetadata(
                originalURL: sourceURL,
                expectedBytes: response.expectedContentLength,
                etag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                createdAt: Date()
            )
            try bundle.prepareForFreshDownload(with: metadata)
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: 0,
                expectedTotal: metadata.expectedBytes,
                progressHandler: progressHandler
            )

        case 206:
            // Partial Content — server honored our Range. Validate Content-Range.
            guard let metadata = resumeMetadata else {
                // Server sent 206 without us asking; treat as a server error.
                Self.logger.error("Server returned 206 Partial Content without a Range request")
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            if let header = response.value(forHTTPHeaderField: "Content-Range"),
                let parsed = Self.parseContentRange(header),
                parsed.start != resumeOffset
            {
                Self.logger.warning(
                    "Content-Range start \(parsed.start, privacy: .public) ≠ requested offset \(resumeOffset, privacy: .public); trusting server"
                )
            }
            try await streamBytes(
                from: responseBytes,
                into: bundle,
                startingAt: resumeOffset,
                expectedTotal: metadata.expectedBytes,
                progressHandler: progressHandler
            )

        case 416:
            // Range Not Satisfiable — usually means our `Contents/data` is already
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
                url: sourceURL, resumeOffset: nil, ifRangeETag: nil, ifRangeLastModified: nil)
            guard freshResponse.statusCode == 200 else {
                throw IPSWError.downloadFailed(URLError(.badServerResponse))
            }
            let metadata = IPSWDownloadMetadata(
                originalURL: sourceURL,
                expectedBytes: freshResponse.expectedContentLength,
                etag: freshResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: freshResponse.value(forHTTPHeaderField: "Last-Modified"),
                createdAt: Date()
            )
            try bundle.saveMetadata(metadata)
            try await streamBytes(
                from: freshBytes,
                into: bundle,
                startingAt: 0,
                expectedTotal: metadata.expectedBytes,
                progressHandler: progressHandler
            )

        default:
            Self.logger.error("Restore image GET returned HTTP \(response.statusCode, privacy: .public)")
            throw IPSWError.downloadFailed(URLError(.badServerResponse))
        }

        // Successful completion — move bytes to the user's chosen path and trash the bundle.
        try bundle.finalize(to: destinationURL)

        let metadata = (try? IPSWDownloadMetadata.from(response: response, fallbackURL: sourceURL))
        let expected = metadata?.expectedBytes ?? response.expectedContentLength
        let finalProgress = DownloadProgress(
            bytesWritten: expected, totalBytes: expected, bytesPerSecond: 0)
        await MainActor.run { progressHandler(finalProgress) }
        Self.logger.info(
            "Restore image downloaded to \(destinationURL.lastPathComponent, privacy: .public)"
        )
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
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // trashItem reports the missing-file case via NSCocoaErrorDomain too.
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

    private func performGET(
        url: URL,
        resumeOffset: Int64?,
        ifRangeETag: String?,
        ifRangeLastModified: String?
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
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
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IPSWError.downloadFailed(URLError(.badServerResponse))
        }
        return (bytes, httpResponse)
    }

    private func streamBytes(
        from sequence: URLSession.AsyncBytes,
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
        var buffer: [UInt8] = []
        buffer.reserveCapacity(Self.writeChunkSize)

        do {
            for try await byte in sequence {
                buffer.append(byte)
                if buffer.count >= Self.writeChunkSize {
                    try handle.write(contentsOf: buffer)
                    totalWritten += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    Self.report(
                        bytesWritten: totalWritten,
                        expectedTotal: expectedTotal,
                        smoother: &smoother,
                        progressHandler: progressHandler
                    )
                }
            }
        } catch is CancellationError {
            if !buffer.isEmpty {
                try? handle.write(contentsOf: buffer)
            }
            Self.logger.info("Restore image download cancelled")
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            if !buffer.isEmpty {
                try? handle.write(contentsOf: buffer)
            }
            Self.logger.info("Restore image download cancelled (URLError.cancelled)")
            throw CancellationError()
        } catch {
            if !buffer.isEmpty {
                try? handle.write(contentsOf: buffer)
            }
            Self.logger.error(
                "Restore image download failed mid-stream: \(error.localizedDescription, privacy: .public)"
            )
            throw IPSWError.downloadFailed(error)
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
        }
        try handle.close()
        handleClosed = true
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

    /// 256 KB — large enough to amortize syscall overhead, small enough that the
    /// in-memory buffer stays modest for a multi-GB download.
    private static let writeChunkSize = 256 * 1024

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
/// Metadata serialized as `Contents/Info.plist` inside a `.kernovadownload` bundle.
struct IPSWDownloadMetadata: Codable, Sendable, Equatable {
    var originalURL: URL
    var expectedBytes: Int64
    var etag: String?
    var lastModified: String?
    var createdAt: Date

    static func from(response: HTTPURLResponse, fallbackURL: URL) throws -> IPSWDownloadMetadata {
        IPSWDownloadMetadata(
            originalURL: response.url ?? fallbackURL,
            expectedBytes: response.expectedContentLength,
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            createdAt: Date()
        )
    }
}

/// File-system helper for an in-progress IPSW download bundle.
///
/// Layout:
/// ```
/// <url>.kernovadownload/
///   Contents/
///     Info.plist     ← IPSWDownloadMetadata
///     data           ← partial bytes; file size IS the resume offset
/// ```
///
/// The UTI registration in the app's `Info.plist` declares `.kernovadownload`
/// as a package conforming to `com.apple.package` so Finder renders the
/// directory as a single icon with Show Package Contents support.
struct IPSWBundle: Sendable {
    let url: URL

    var contentsURL: URL { url.appendingPathComponent("Contents", isDirectory: true) }
    var dataURL: URL { contentsURL.appendingPathComponent("data") }
    var infoPlistURL: URL { contentsURL.appendingPathComponent("Info.plist") }

    /// `true` when the bundle directory exists on disk (regardless of internal validity).
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    /// Current size of `Contents/data` on disk; the resume offset for the next request.
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

    /// Creates `Contents/`, writes `Info.plist`, ensures an empty `data` file exists.
    ///
    /// Called on the fresh-download path (response 200) — if the bundle already exists,
    /// the data file is truncated to zero.
    func prepareForFreshDownload(with metadata: IPSWDownloadMetadata) throws {
        try FileManager.default.createDirectory(
            at: contentsURL, withIntermediateDirectories: true)
        try saveMetadata(metadata)
        if FileManager.default.fileExists(atPath: dataURL.path(percentEncoded: false)) {
            try truncateData()
        } else {
            FileManager.default.createFile(
                atPath: dataURL.path(percentEncoded: false), contents: nil)
        }
    }

    /// Truncates `Contents/data` to zero bytes (used when the remote file changed mid-resume).
    func truncateData() throws {
        let handle = try FileHandle(forWritingTo: dataURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }

    /// Moves `Contents/data` to the final IPSW destination and trashes the bundle.
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

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "The restore image does not have a download URL."
        case .downloadFailed(let underlyingError):
            "Failed to download restore image: \(underlyingError.localizedDescription)"
        }
    }
}
