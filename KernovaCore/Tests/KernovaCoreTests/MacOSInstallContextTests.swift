import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("MacOSInstallContext Tests", .caseScoped)
struct MacOSInstallContextTests {
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

    // MARK: - Catalog Version Source

    @Test("A catalog context round-trips its pinned image")
    func catalogContextRoundTrips() throws {
        let url = try #require(
            URL(string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw"))
        let original = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: "/Users/me/Downloads/UniversalMac_15.6.1_24G90_Restore.ipsw",
            remoteURL: url,
            version: "15.6.1",
            build: "24G90"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MacOSInstallContext.self, from: data)

        #expect(decoded == original)
        #expect(decoded.source == .catalogVersion)
        #expect(decoded.remoteURL == url)
        #expect(decoded.version == "15.6.1")
        #expect(decoded.build == "24G90")
    }
}
