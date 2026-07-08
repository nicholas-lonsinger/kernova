import Foundation
import Testing

@testable import KernovaKit

@Suite("KernovaAppGroup")
struct KernovaAppGroupTests {
    // Writes a throwaway `.bundle` whose Info.plist carries `appGroup` under the
    // helper's key, loads it, and hands it to `body` — so `identifier(from:)` is
    // exercised against a real Info dictionary without touching the test runner's
    // own bundle. The missing-key fallback path is intentionally not tested: it
    // trips `assertionFailure`, which aborts a Debug test run.
    private func withStubBundle(
        appGroup: String,
        _ body: (Bundle) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KernovaAppGroupTests-\(UUID().uuidString).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: [KernovaAppGroup.infoPlistKey: appGroup],
            format: .xml,
            options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        try body(bundle)
    }

    @Test("Resolves the team-prefixed Debug identifier")
    func resolvesTeamPrefixedDebugIdentifier() throws {
        try withStubBundle(appGroup: "8MT4P4GZL2.app.kernova") { bundle in
            #expect(KernovaAppGroup.identifier(from: bundle) == "8MT4P4GZL2.app.kernova")
        }
    }

    @Test("Resolves the canonical Release identifier")
    func resolvesCanonicalReleaseIdentifier() throws {
        try withStubBundle(appGroup: "group.app.kernova") { bundle in
            #expect(KernovaAppGroup.identifier(from: bundle) == "group.app.kernova")
        }
    }
}
