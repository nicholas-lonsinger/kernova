import Foundation
import Testing

@testable import Kernova

#if arch(arm64)
/// Integration tests for `IPSWService.downloadRestoreImage`.
///
/// Drives the full HTTP flow against a stub `URLProtocol`. The stub returns
/// canned responses keyed by `Range` header presence so the same suite can
/// exercise fresh downloads, resume happy paths, file-changed scenarios, and
/// 416 handling without touching the network.
@Suite("IPSWService Download Tests", .serialized)
struct IPSWServiceDownloadTests {
    // MARK: - Test infrastructure

    /// Creates a unique temp directory for a single test.
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IPSWServiceDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds an `IPSWService` whose `URLSession` routes every request through `StubURLProtocol`.
    ///
    /// The configuration is `.ephemeral` to avoid any disk caching between tests.
    private static func makeServiceWithStub() -> IPSWService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses =
            [StubURLProtocol.self] + (configuration.protocolClasses ?? [])
        return IPSWService(sessionConfiguration: configuration)
    }

    private static func mustParseURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            assertionFailure("IPSWServiceDownloadTests: failed to construct URL from '\(string)'")
            return URL(filePath: "/")
        }
        return url
    }

    private static let remoteURL = mustParseURL("https://stub.kernova.test/RestoreImage.ipsw")
    private static let staleRemoteURL = mustParseURL("https://stub.kernova.test/OldBuild.ipsw")

    // MARK: - Tests

    @Test("Fresh download writes bytes to destination and trashes the bundle")
    func freshDownloadCompletes() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let payload = Data(repeating: 0xAA, count: 256 * 1024 + 100)
        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return .fullResponse(
                url: (request.url ?? Self.remoteURL),
                body: payload,
                etag: "\"v1\"",
                lastModified: "Mon, 01 Jan 2026 00:00:00 GMT"
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let written = try Data(contentsOf: destination)
        #expect(written == payload)

        // Bundle has been finalized (moved to Trash); no longer next to destination.
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        var isDir: ObjCBool = false
        let exists =
            FileManager.default.fileExists(
                atPath: bundleURL.path, isDirectory: &isDir) && isDir.boolValue
        #expect(!exists)
    }

    @Test("Resume sends Range/If-Range and appends 206 body to existing bytes")
    func resumeAppendsPartialContent() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        let prefix = Data(repeating: 0x11, count: 1024)
        let suffix = Data(repeating: 0x22, count: 2048)
        let fullPayload = prefix + suffix

        // Seed the bundle with the first half of the payload and metadata.
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: "Mon, 01 Jan 2026 00:00:00 GMT",
                createdAt: Date()
            )
        )
        try prefix.write(to: bundle.dataURL)
        #expect(bundle.partialByteCount == Int64(prefix.count))

        StubURLProtocol.handler = { request in
            // Verify resume headers
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(prefix.count)-")
            #expect(request.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
            return .partialResponse(
                url: (request.url ?? Self.remoteURL),
                body: suffix,
                start: Int64(prefix.count),
                end: Int64(fullPayload.count - 1),
                total: Int64(fullPayload.count)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        let written = try Data(contentsOf: destination)
        #expect(written == fullPayload)
    }

    @Test("File-changed (200 on Range request) truncates bundle and restarts")
    func fileChangedRestartsFromZero() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        // Seed bundle with stale partial data. The new payload is INTENTIONALLY
        // shorter than the stale data; if truncation didn't happen, the final
        // file would still contain the tail of the stale bytes and would be
        // larger than `newPayload.count`. That's how we observe truncation
        // instead of just confirming "no bytes overlap visibly."
        let stale = Data(repeating: 0xFF, count: 8192)
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"stale-v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try stale.write(to: bundle.dataURL)

        let newPayload = Data(repeating: 0x33, count: 4096)
        StubURLProtocol.handler = { request in
            // Server ignores If-Range and sends a full 200 — file changed.
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=8192-")
            return .fullResponse(url: (request.url ?? Self.remoteURL), body: newPayload, etag: "\"v2\"")
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        let written = try Data(contentsOf: destination)
        #expect(written == newPayload)
        // Crucial: size matches the new payload, NOT max(stale, new). If
        // truncation hadn't happened, we'd see 8192 stale bytes + something.
        #expect(written.count == newPayload.count)
    }

    @Test("416 with full file on disk finalizes without re-downloading")
    func unsatisfiableRangeWithCompleteFileFinalizes() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        let complete = Data(repeating: 0x77, count: 4096)
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try complete.write(to: bundle.dataURL)

        StubURLProtocol.handler = { request in
            .response(
                url: (request.url ?? Self.remoteURL),
                statusCode: 416,
                body: Data(),
                headers: ["Content-Range": "bytes */\(complete.count)"]
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        let written = try Data(contentsOf: destination)
        #expect(written == complete)
    }

    @Test("206 response without a parseable Content-Range fails fast")
    func partialResponseMissingContentRangeFailsFast() async throws {
        // We can't trust `response.expectedContentLength` on 206 — it reports
        // the partial-body length, not the full file size — so a 206 with no
        // (or unparseable) Content-Range must throw rather than feed a wrong
        // total into the progress UI.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        // Seed a partial bundle so the resume Range header is sent and the
        // 206 branch is selected.
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try Data(repeating: 0x11, count: 1024).write(to: bundle.dataURL)

        StubURLProtocol.handler = { request in
            // Status 206 with NO Content-Range header — the failure case.
            .response(
                url: request.url ?? Self.remoteURL,
                statusCode: 206,
                body: Data(repeating: 0x22, count: 512),
                headers: [:]
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        do {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                progressHandler: { _ in }
            )
            Issue.record("Expected fail-fast on 206 without Content-Range")
        } catch IPSWError.downloadFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Bundle preserved for a future retry — the failure is on the
        // protocol side, the partial bytes on disk are still valid for resume.
        #expect(bundle.exists)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("4xx server error throws IPSWError.downloadFailed")
    func httpErrorThrows() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        StubURLProtocol.handler = { request in
            .response(url: (request.url ?? Self.remoteURL), statusCode: 404, body: Data(), headers: [:])
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        do {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                progressHandler: { _ in }
            )
            Issue.record("Expected downloadRestoreImage to throw on 404")
        } catch IPSWError.downloadFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Skip-existing fast path returns immediately when destination already exists")
    func skipExistingFastPath() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let preExisting = Data(repeating: 0x99, count: 2048)
        try preExisting.write(to: destination)

        StubURLProtocol.handler = { _ in
            Issue.record("Stub should not have been called when skip-existing fast path fires")
            return .response(url: Self.remoteURL, statusCode: 500, body: Data(), headers: [:])
        }
        defer { StubURLProtocol.handler = nil }

        let progressBox = ProgressRecorder()
        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { [progressBox] progress in
                progressBox.record(progress.bytesWritten)
            }
        )
        // Progress callbacks now use `await MainActor.run` end-to-end, so
        // they're observable as soon as the await above returns — no sleep.
        let samples = await progressBox.snapshot()
        #expect(!samples.isEmpty)
        #expect(samples.last == Int64(preExisting.count))
    }

    @Test("Mid-stream network failure throws downloadFailed and preserves the bundle")
    func midStreamErrorPreservesBundle() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        // Deliver enough partial bytes (≥ writeChunkSize) so at least one
        // chunked write commits to disk before the error fires.
        let partial = Data(repeating: 0x55, count: 512 * 1024)
        StubURLProtocol.handler = { request in
            .midStreamError(
                url: request.url ?? Self.remoteURL,
                declaredLength: 4 * 1024 * 1024,
                partialBody: partial,
                error: URLError(.networkConnectionLost)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        do {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                progressHandler: { _ in }
            )
            Issue.record("Expected downloadRestoreImage to throw on mid-stream failure")
        } catch IPSWError.downloadFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Destination was never finalized; bundle is preserved for next attempt.
        // We don't assert on `partialByteCount` because URLSession may surface
        // the error before yielding any of the buffered bytes — what matters is
        // that the bundle survived for a future resume.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let bundle = IPSWBundle(url: IPSWService.resumeBundleURL(for: destination))
        #expect(bundle.exists)
        #expect(bundle.partialByteCount <= Int64(partial.count))
    }

    @Test("Corrupt Info.plist causes the bundle to be discarded and download to restart fresh")
    func corruptBundleIsDiscarded() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)

        // Hand-craft a bundle with garbage in Info.plist and bogus data.
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let bundle = IPSWBundle(url: bundleURL)
        try Data("not a plist".utf8).write(to: bundle.infoPlistURL)
        try Data(repeating: 0xCC, count: 1024).write(to: bundle.dataURL)

        let payload = Data(repeating: 0x42, count: 2048)
        StubURLProtocol.handler = { request in
            // The corrupt bundle must be discarded — request should be fresh
            // (no Range header from stale state).
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return .fullResponse(
                url: request.url ?? Self.remoteURL, body: payload, etag: "\"v1\"")
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        let written = try Data(contentsOf: destination)
        #expect(written == payload)
    }

    @Test("Bundle with different originalURL is discarded; fresh download issued")
    func urlMismatchDiscardsBundle() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        // Seed bundle with metadata pointing at a DIFFERENT URL than the
        // caller will pass.
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.staleRemoteURL,
                etag: "\"old\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try Data(repeating: 0x99, count: 4096).write(to: bundle.dataURL)

        let payload = Data(repeating: 0x77, count: 2048)
        StubURLProtocol.handler = { request in
            // Should target the NEW URL (caller's remoteURL), not the stale one.
            #expect(request.url == Self.remoteURL)
            // Should be a fresh request (no Range header from stale state).
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return .fullResponse(
                url: request.url ?? Self.remoteURL, body: payload, etag: "\"new\"")
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { _ in }
        )

        let written = try Data(contentsOf: destination)
        #expect(written == payload)
    }

    @Test("206 with Content-Range start that disagrees with our resume offset throws and discards the bundle")
    func partialContentRangeMismatchDiscardsBundleAndThrows() async throws {
        // Server returns `Content-Range: bytes 0-499/N` to our `Range: bytes=1024-`
        // request — the start doesn't line up with what we asked for. Writing
        // the body at our requested offset would leave a corrupt prefix on
        // disk. The service must trash the bundle and throw rather than splice.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try Data(repeating: 0x11, count: 1024).write(to: bundle.dataURL)

        StubURLProtocol.handler = { request in
            // Server returns the wrong range — start at 0 even though we asked
            // for bytes=1024-.
            .partialResponse(
                url: request.url ?? Self.remoteURL,
                body: Data(repeating: 0x22, count: 500),
                start: 0,
                end: 499,
                total: 1500
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        do {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                progressHandler: { _ in }
            )
            Issue.record("Expected throw on 206 Content-Range start mismatch")
        } catch IPSWError.downloadFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Bundle should be discarded so the next attempt starts fresh.
        #expect(!bundle.exists)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("416 with size mismatch discards the bundle and throws so the next start restarts cleanly")
    func unsatisfiableRangeWithSizeMismatchDiscardsBundleAndThrows() async throws {
        // The bundle has 4096 bytes; the server says the full file is 2048
        // bytes (it shrank). Our bytes-on-disk are no longer a valid prefix
        // of the file. The service must discard so the next Start runs a
        // fresh 200 GET via `loadResumeMetadata`'s no-bundle path.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try Data(repeating: 0x55, count: 4096).write(to: bundle.dataURL)

        StubURLProtocol.handler = { request in
            .response(
                url: request.url ?? Self.remoteURL,
                statusCode: 416,
                body: Data(),
                headers: ["Content-Range": "bytes */2048"]
            )
        }
        defer { StubURLProtocol.handler = nil }

        let service = Self.makeServiceWithStub()
        do {
            try await service.downloadRestoreImage(
                from: Self.remoteURL,
                to: destination,
                progressHandler: { _ in }
            )
            Issue.record("Expected throw on 416 with mismatched size")
        } catch IPSWError.downloadFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!bundle.exists)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Resume emits an initial progress callback at the existing offset")
    func resumeIncludesInitialProgress() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        let bundleURL = IPSWService.resumeBundleURL(for: destination)
        let bundle = IPSWBundle(url: bundleURL)

        let prefix = Data(repeating: 0x11, count: 4096)
        let suffix = Data(repeating: 0x22, count: 8192)
        let total = prefix + suffix

        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )
        try prefix.write(to: bundle.dataURL)

        StubURLProtocol.handler = { request in
            .partialResponse(
                url: request.url ?? Self.remoteURL,
                body: suffix,
                start: Int64(prefix.count),
                end: Int64(total.count - 1),
                total: Int64(total.count)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let recorder = ProgressRecorder()
        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { [recorder] progress in
                recorder.record(progress.bytesWritten)
            }
        )

        let samples = await recorder.snapshot()
        #expect(samples.first == Int64(prefix.count), "First sample should match the resume offset")
        #expect(samples.last == Int64(total.count), "Last sample should match the full file size")
    }

    @Test("streamBytes throws CancellationError when the surrounding Task is cancelled")
    func streamBytesCancellation() async throws {
        // We bypass URLSession here — the prior URLProtocol-driven cancellation
        // test was timing-dependent because URLProtocol cleanup races with
        // session lifecycle across tests. Driving `streamBytes` directly with
        // a hand-controlled `AsyncThrowingStream` lets us coordinate cancel +
        // yield deterministically: the producer yields a chunk to unblock the
        // for-await, then the next iteration's `Task.checkCancellation()` fires.
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("R.kernovadownload")
        let bundle = IPSWBundle(url: bundleURL)
        try bundle.prepareForFreshDownload(
            with: IPSWDownloadMetadata(
                originalURL: Self.remoteURL,
                etag: "\"v1\"",
                lastModified: nil,
                createdAt: Date()
            )
        )

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let service = IPSWService()

        // Coordination signal: fires when streamBytes emits its initial-offset
        // progress, proving it's now sitting inside the for-await waiting for
        // the next yield.
        let firstProgress = AsyncStream<Void>.makeStream()
        let firstProgressContinuation = firstProgress.continuation
        let signaled = SignalGate()

        let streamTask = Task { [signaled] in
            try await service.streamBytes(
                from: stream,
                into: bundle,
                startingAt: 0,
                expectedTotal: 4096,
                progressHandler: { @Sendable [signaled, firstProgressContinuation] _ in
                    if signaled.fireOnce() {
                        firstProgressContinuation.yield()
                        firstProgressContinuation.finish()
                    }
                }
            )
        }

        // Wait for streamBytes to reach the for-await.
        for await _ in firstProgress.stream { break }

        // Cancel, then yield one chunk so the loop body wakes and runs its
        // `try Task.checkCancellation()`.
        streamTask.cancel()
        continuation.yield(Data(repeating: 0xBB, count: 128))
        continuation.finish()

        do {
            try await streamTask.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Bundle preserved on cancel (non-destructive cancel UX).
        #expect(bundle.exists)
    }

    @Test("Progress callbacks report monotonically non-decreasing bytesWritten")
    func progressIsMonotonic() async throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        // Build a payload comfortably larger than the 256 KB write-chunk so
        // multiple progress reports fire.
        let payload = Data(repeating: 0x44, count: 1024 * 1024)
        StubURLProtocol.handler = { request in
            .fullResponse(url: (request.url ?? Self.remoteURL), body: payload, etag: "\"v1\"")
        }
        defer { StubURLProtocol.handler = nil }

        let progressBox = ProgressRecorder()
        let service = Self.makeServiceWithStub()
        try await service.downloadRestoreImage(
            from: Self.remoteURL,
            to: destination,
            progressHandler: { [progressBox] progress in
                progressBox.record(progress.bytesWritten)
            }
        )

        let samples = await progressBox.snapshot()
        // Last sample should equal the full payload size.
        #expect(samples.last == Int64(payload.count))
        // Each successive sample is >= the previous one.
        for i in 1..<samples.count {
            #expect(samples[i] >= samples[i - 1])
        }
    }
}

// MARK: - Helpers

/// Records progress samples on the MainActor so we can read them back after
/// the download completes.
@MainActor
final class ProgressRecorder {
    private var samples: [Int64] = []
    func record(_ bytes: Int64) { samples.append(bytes) }
    func snapshot() -> [Int64] { samples }
}

/// One-shot, thread-safe latch used by the cancellation test to fire its
/// "first progress arrived" signal exactly once even if the handler is
/// invoked more than once before the test observes the signal.
final class SignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Stub URLProtocol that intercepts requests for tests.
///
/// Tests set `StubURLProtocol.handler` to control the response shape per case.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let response: HTTPURLResponse
        let body: Data
        /// When set, body is delivered fully but the response's
        /// Content-Length declares a larger size, mimicking a truncated transfer.
        let declaresLargerLength: Bool
        /// When set, the stub delivers the response + (partial) body, then
        /// signals `didFailWithError(_:)` to simulate a mid-stream network drop.
        let failAfterBody: URLError?

        private static func makeResponse(
            url: URL, statusCode: Int, headers: [String: String]
        ) -> HTTPURLResponse {
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: headers)
            else {
                preconditionFailure(
                    "StubURLProtocol: HTTPURLResponse construction failed for status \(statusCode)"
                )
            }
            return response
        }

        static func fullResponse(
            url: URL,
            body: Data,
            etag: String? = nil,
            lastModified: String? = nil
        ) -> StubResponse {
            var headers: [String: String] = ["Content-Length": "\(body.count)"]
            if let etag { headers["ETag"] = etag }
            if let lastModified { headers["Last-Modified"] = lastModified }
            return StubResponse(
                response: makeResponse(url: url, statusCode: 200, headers: headers),
                body: body, declaresLargerLength: false, failAfterBody: nil)
        }

        static func partialResponse(
            url: URL,
            body: Data,
            start: Int64,
            end: Int64,
            total: Int64
        ) -> StubResponse {
            let headers: [String: String] = [
                "Content-Length": "\(body.count)",
                "Content-Range": "bytes \(start)-\(end)/\(total)",
            ]
            return StubResponse(
                response: makeResponse(url: url, statusCode: 206, headers: headers),
                body: body, declaresLargerLength: false, failAfterBody: nil)
        }

        static func response(
            url: URL,
            statusCode: Int,
            body: Data,
            headers: [String: String]
        ) -> StubResponse {
            var allHeaders = headers
            if allHeaders["Content-Length"] == nil {
                allHeaders["Content-Length"] = "\(body.count)"
            }
            return StubResponse(
                response: makeResponse(url: url, statusCode: statusCode, headers: allHeaders),
                body: body, declaresLargerLength: false, failAfterBody: nil)
        }

        static func truncatedResponse(
            url: URL,
            declaredLength: Int,
            actualBody: Data
        ) -> StubResponse {
            let headers: [String: String] = ["Content-Length": "\(declaredLength)"]
            return StubResponse(
                response: makeResponse(url: url, statusCode: 200, headers: headers),
                body: actualBody, declaresLargerLength: true, failAfterBody: nil)
        }

        /// Delivers `partialBody` then signals `didFailWithError:` to simulate a
        /// mid-stream network drop. `declaredLength` should be larger than
        /// `partialBody.count` so the receiver sees an incomplete transfer.
        static func midStreamError(
            url: URL,
            declaredLength: Int,
            partialBody: Data,
            error: URLError
        ) -> StubResponse {
            let headers: [String: String] = ["Content-Length": "\(declaredLength)"]
            return StubResponse(
                response: makeResponse(url: url, statusCode: 200, headers: headers),
                body: partialBody, declaresLargerLength: true, failAfterBody: error)
        }
    }

    // RATIONALE: URLProtocol is instantiated per-request by URLSession on an
    // internal queue; the test sets `handler` before kicking off the download
    // and clears it after, so the global isn't racy in practice. Marking it
    // nonisolated(unsafe) sidesteps Sendable diagnostics for the closure.
    nonisolated(unsafe) static var handler: ((URLRequest) -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "StubURLProtocol", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No handler set"]
                )
            )
            return
        }
        let stub = handler(request)
        client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        if let error = stub.failAfterBody {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif
