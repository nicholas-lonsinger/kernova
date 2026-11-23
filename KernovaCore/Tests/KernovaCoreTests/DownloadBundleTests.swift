import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("DownloadBundle Tests", .caseScoped)
struct DownloadBundleTests {
    private let scratch = TestScratchDirectory(prefix: "DownloadBundleTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    @Test("resumeBundleURL swaps .ipsw for .kernovadownload")
    func resumeBundleURLSwapsExtension() {
        let destination = URL(fileURLWithPath: "/tmp/Foo/RestoreImage.ipsw")
        let bundle = DownloadService.resumeBundleURL(for: destination)
        #expect(bundle.lastPathComponent == "RestoreImage.kernovadownload")
        #expect(bundle.deletingLastPathComponent().path == "/tmp/Foo")
    }

    @Test("Content-Range accepts header without the `bytes ` unit prefix")
    func contentRangeAcceptsMissingBytesPrefix() {
        // Permissive on the unit token — the parseable shape `start-end/total`
        // is what callers actually rely on. Documenting the current behavior
        // so it doesn't drift silently.
        let result = DownloadService.parseContentRange("0-499/1234")
        #expect(result?.start == 0)
        #expect(result?.end == 499)
        #expect(result?.total == 1234)
    }

    @Test("Content-Range tolerates whitespace inside the value")
    func contentRangeToleratesInternalWhitespace() {
        // Real-world proxies occasionally insert spaces around `-` or `/`.
        // The canonical form is still `bytes 0-499/1234`; accepting the
        // spaced variant is defensive parsing.
        let spaced = DownloadService.parseContentRange("bytes 0 - 499 / 1234")
        #expect(spaced?.start == 0)
        #expect(spaced?.end == 499)
        #expect(spaced?.total == 1234)

        let leading = DownloadService.parseContentRange("  bytes 100-200/300  ")
        #expect(leading?.start == 100)
        #expect(leading?.end == 200)
        #expect(leading?.total == 300)
    }
}
