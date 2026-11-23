import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMSnapshot Tests", .caseScoped)
struct VMSnapshotTests {

    // MARK: - Persistence

    @Test("A manifest entry carrying no kind decodes as a memory-and-disks snapshot")
    func snapshotWithoutKindDecodesWarm() throws {
        let id = UUID()
        let json = """
            {"snapshots":[{"id":"\(id.uuidString)","name":"One",\
            "createdAt":"2026-01-02T03:04:05Z","notes":""}]}
            """
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMSnapshotManifestRecord.self, from: Data(json.utf8))
        #expect(decoded.snapshots.first { $0.id == id }?.kind == .warm)
    }
}
