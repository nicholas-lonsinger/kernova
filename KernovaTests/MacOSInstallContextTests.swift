import Foundation
import Testing

@testable import Kernova

@Suite("MacOSInstallContext Tests")
struct MacOSInstallContextTests {
    @Test("Default initializer leaves requestedFreshDownload false")
    func defaultsFreshFalse() {
        let ctx = MacOSInstallContext(source: .downloadLatest)
        #expect(!ctx.requestedFreshDownload)
    }

    @Test("Decoding JSON without requestedFreshDownload defaults to false")
    func decodeMissingFieldDefaultsFalse() throws {
        // Mirrors the on-disk shape from before the field was added — any
        // installContext persisted by an older Kernova build must continue to
        // decode cleanly.
        let json = """
            {
                "source": "downloadLatest",
                "downloadDestinationPath": "/Users/me/Downloads/R.ipsw"
            }
            """
        let ctx = try JSONDecoder().decode(MacOSInstallContext.self, from: Data(json.utf8))
        #expect(ctx.source == .downloadLatest)
        #expect(ctx.downloadDestinationPath == "/Users/me/Downloads/R.ipsw")
        #expect(!ctx.requestedFreshDownload)
    }

    @Test("Decoding JSON with requestedFreshDownload honors the value")
    func decodeHonorsPersistedValue() throws {
        let json = """
            {
                "source": "downloadLatest",
                "downloadDestinationPath": "/Users/me/Downloads/R.ipsw",
                "requestedFreshDownload": true
            }
            """
        let ctx = try JSONDecoder().decode(MacOSInstallContext.self, from: Data(json.utf8))
        #expect(ctx.requestedFreshDownload)
    }

    @Test("Roundtrip preserves the flag")
    func roundtripPreservesFlag() throws {
        let original = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/Users/me/Downloads/R.ipsw",
            requestedFreshDownload: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MacOSInstallContext.self, from: data)
        #expect(decoded == original)
        #expect(decoded.requestedFreshDownload)
    }

    @Test("Decoding JSON without localIPSWBookmark decodes to nil")
    func decodeMissingBookmarkDefaultsNil() throws {
        // Pre-sandbox on-disk shape: localFile contexts carried only the raw
        // path. Must keep decoding cleanly, with the bookmark absent.
        let json = """
            {
                "source": "localFile",
                "localIPSWPath": "/Users/me/R.ipsw"
            }
            """
        let ctx = try JSONDecoder().decode(MacOSInstallContext.self, from: Data(json.utf8))
        #expect(ctx.localIPSWPath == "/Users/me/R.ipsw")
        #expect(ctx.localIPSWBookmark == nil)
    }

    @Test("Roundtrip preserves localIPSWBookmark")
    func roundtripPreservesBookmark() throws {
        let original = MacOSInstallContext(
            source: .localFile,
            localIPSWPath: "/Users/me/R.ipsw",
            localIPSWBookmark: Data([0x01, 0x02, 0x03])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MacOSInstallContext.self, from: data)
        #expect(decoded == original)
        #expect(decoded.localIPSWBookmark == Data([0x01, 0x02, 0x03]))
    }

    @Test("Equality considers requestedFreshDownload")
    func equalityIncludesFlag() {
        let a = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/p.ipsw",
            requestedFreshDownload: false
        )
        let b = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/p.ipsw",
            requestedFreshDownload: true
        )
        #expect(a != b)
    }
}
