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
