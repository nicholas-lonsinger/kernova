import Foundation
import Testing

@testable import Kernova

#if arch(arm64)
@Suite("IPSWBundle Tests")
struct IPSWBundleTests {
    /// Creates a unique temp directory for a single test and returns it.
    ///
    /// The caller is responsible for removing it (typically via `defer`).
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPSWBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let defaultMetadataURL: URL = {
        guard let url = URL(string: "https://example.com/RestoreImage.ipsw") else {
            assertionFailure("IPSWBundleTests: failed to construct default metadata URL")
            return URL(filePath: "/")
        }
        return url
    }()

    private static func makeMetadata(
        url: URL = defaultMetadataURL,
        etag: String? = "\"abc123\"",
        lastModified: String? = "Mon, 01 Jan 2026 00:00:00 GMT"
    ) -> IPSWDownloadMetadata {
        IPSWDownloadMetadata(
            originalURL: url,
            etag: etag,
            lastModified: lastModified,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("resumeBundleURL swaps .ipsw for .kernovadownload")
    func resumeBundleURLSwapsExtension() {
        let destination = URL(fileURLWithPath: "/tmp/Foo/RestoreImage.ipsw")
        let bundle = IPSWService.resumeBundleURL(for: destination)
        #expect(bundle.lastPathComponent == "RestoreImage.kernovadownload")
        #expect(bundle.deletingLastPathComponent().path == "/tmp/Foo")
    }

    @Test("prepareForFreshDownload creates Info.plist and empty data file at bundle root")
    func prepareForFreshDownloadCreatesLayout() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("RestoreImage.kernovadownload")
        let bundle = IPSWBundle(url: bundleURL)
        let metadata = Self.makeMetadata()

        try bundle.prepareForFreshDownload(with: metadata)

        #expect(bundle.exists)
        #expect(FileManager.default.fileExists(atPath: bundle.infoPlistURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.dataURL.path))
        #expect(bundle.partialByteCount == 0)

        let loaded = try bundle.loadMetadata()
        #expect(loaded == metadata)
    }

    @Test("partialByteCount reflects file size after appends")
    func partialByteCountTracksFileSize() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = IPSWBundle(url: temp.appendingPathComponent("R.kernovadownload"))
        try bundle.prepareForFreshDownload(with: Self.makeMetadata())

        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 1024))
        try handle.close()
        #expect(bundle.partialByteCount == 1024)

        let handle2 = try FileHandle(forWritingTo: bundle.dataURL)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(repeating: 0xCD, count: 512))
        try handle2.close()
        #expect(bundle.partialByteCount == 1024 + 512)
    }

    @Test("truncateData zeroes the data file")
    func truncateDataZeroesFile() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = IPSWBundle(url: temp.appendingPathComponent("R.kernovadownload"))
        try bundle.prepareForFreshDownload(with: Self.makeMetadata())

        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 4096))
        try handle.close()
        #expect(bundle.partialByteCount == 4096)

        try bundle.truncateData()
        #expect(bundle.partialByteCount == 0)
    }

    @Test("loadMetadata throws on malformed Info.plist")
    func loadMetadataThrowsOnGarbage() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = IPSWBundle(url: temp.appendingPathComponent("R.kernovadownload"))
        try bundle.prepareForFreshDownload(with: Self.makeMetadata())

        try Data("not a plist".utf8).write(to: bundle.infoPlistURL, options: .atomic)
        #expect(throws: (any Error).self) {
            try bundle.loadMetadata()
        }
    }

    @Test("finalize moves data to destination and trashes bundle")
    func finalizeMovesDataAndTrashes() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = IPSWBundle(url: temp.appendingPathComponent("R.kernovadownload"))
        try bundle.prepareForFreshDownload(with: Self.makeMetadata())

        let payload = Data(repeating: 0x42, count: 8192)
        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.write(contentsOf: payload)
        try handle.close()

        let destination = temp.appendingPathComponent("R.ipsw")
        try bundle.finalize(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let movedData = try Data(contentsOf: destination)
        #expect(movedData == payload)
        // Bundle goes to Trash, so it should be gone from its original location.
        #expect(!bundle.exists)
    }

    @Test("finalize replaces an existing file at the destination")
    func finalizeReplacesExistingDestination() throws {
        let temp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundle = IPSWBundle(url: temp.appendingPathComponent("R.kernovadownload"))
        try bundle.prepareForFreshDownload(with: Self.makeMetadata())

        let fresh = Data(repeating: 0xBE, count: 2048)
        let handle = try FileHandle(forWritingTo: bundle.dataURL)
        try handle.write(contentsOf: fresh)
        try handle.close()

        let destination = temp.appendingPathComponent("R.ipsw")
        try Data(repeating: 0x00, count: 100).write(to: destination)

        try bundle.finalize(to: destination)

        let movedData = try Data(contentsOf: destination)
        #expect(movedData == fresh)
    }

    @Test("Content-Range parses canonical bytes header")
    func contentRangeParsesCanonical() {
        let result = IPSWService.parseContentRange("bytes 0-499/1234")
        #expect(result?.start == 0)
        #expect(result?.end == 499)
        #expect(result?.total == 1234)
    }

    @Test("Content-Range returns nil for unparseable input")
    func contentRangeRejectsGarbage() {
        #expect(IPSWService.parseContentRange("garbage") == nil)
        #expect(IPSWService.parseContentRange("bytes */1234") == nil)
    }

    @Test("Content-Range rejects malformed range/total combinations")
    func contentRangeRejectsMalformed() {
        // Empty start (would slice incorrectly if not validated)
        #expect(IPSWService.parseContentRange("bytes -100-499/1234") == nil)
        // Three components in the range portion — extra dash
        #expect(IPSWService.parseContentRange("bytes 100--499/1234") == nil)
        // Non-numeric total
        #expect(IPSWService.parseContentRange("bytes 0-499/foo") == nil)
        // Trailing garbage after total
        #expect(IPSWService.parseContentRange("bytes 0-499/1234; extra") == nil)
        // Missing dash in the start-end portion
        #expect(IPSWService.parseContentRange("bytes 0/1234") == nil)
    }

    @Test("Content-Range accepts header without the `bytes ` unit prefix")
    func contentRangeAcceptsMissingBytesPrefix() {
        // Permissive on the unit token — the parseable shape `start-end/total`
        // is what callers actually rely on. Documenting the current behavior
        // so it doesn't drift silently.
        let result = IPSWService.parseContentRange("0-499/1234")
        #expect(result?.start == 0)
        #expect(result?.end == 499)
        #expect(result?.total == 1234)
    }

    @Test("parseUnsatisfiableTotal extracts total from 416 header")
    func parseUnsatisfiableTotalExtractsTotal() {
        #expect(IPSWService.parseUnsatisfiableTotal("bytes */1234") == 1234)
        #expect(IPSWService.parseUnsatisfiableTotal("*/0") == 0)
        #expect(IPSWService.parseUnsatisfiableTotal(nil) == nil)
        #expect(IPSWService.parseUnsatisfiableTotal("malformed") == nil)
    }
}

@Suite("DownloadSpeedSmoother Tests")
struct DownloadSpeedSmootherTests {
    @Test("First sample returns zero speed")
    func firstSampleReturnsZero() {
        var smoother = DownloadSpeedSmoother()
        let speed = smoother.sample(totalBytes: 0, now: 1000.0)
        #expect(speed == 0)
    }

    @Test("Second sample within throttle window returns nil")
    func throttleWindowReturnsNil() {
        var smoother = DownloadSpeedSmoother()
        _ = smoother.sample(totalBytes: 0, now: 1000.0)
        let speed = smoother.sample(totalBytes: 1_000_000, now: 1000.05)
        #expect(speed == nil)
    }

    @Test("Speed sample after throttle window reflects throughput")
    func speedAfterThrottle() {
        var smoother = DownloadSpeedSmoother()
        _ = smoother.sample(totalBytes: 0, now: 1000.0)
        let speed = smoother.sample(totalBytes: 1_000_000, now: 1001.0) ?? 0
        // 1 MB in 1 s. The smoother's exact "first non-priming sample" formula
        // is an implementation detail; what callers care about is that the
        // reported speed is in the right ballpark, not an exact byte count.
        // 10% tolerance lets the smoothing rule evolve without breaking the
        // test.
        #expect(speed > 0)
        #expect(abs(speed - 1_000_000) < 100_000)
    }

    @Test("EWMA smoothing dampens spikes")
    func ewmaDampensSpikes() {
        var smoother = DownloadSpeedSmoother()
        _ = smoother.sample(totalBytes: 0, now: 1000.0)
        let steady = smoother.sample(totalBytes: 1_000_000, now: 1001.0) ?? 0
        let spiked = smoother.sample(totalBytes: 11_000_000, now: 1002.0) ?? 0
        // After a 10x spike, EWMA(α=0.2) over a steady baseline lands between
        // the prior value and the instantaneous value, never at the spike itself.
        #expect(spiked > steady)
        #expect(spiked < 10_000_000)
    }
}
#endif
