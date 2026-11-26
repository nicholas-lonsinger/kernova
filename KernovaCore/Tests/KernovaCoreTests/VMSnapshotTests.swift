import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMSnapshot Tests", .caseScoped)
struct VMSnapshotTests {

    // MARK: - Persistence

    @Test("The manifest file stores each entry's fields and nothing else")
    func manifestFileKeepsItsShape() throws {
        let snapshot = VMSnapshot(
            id: UUID(), name: "One", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "n", kind: .warm, macAddress: "aa:bb:cc:dd:ee:01")
        let data = try VMConfiguration.makeJSONEncoder().encode(
            VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id).record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((object["snapshots"] as? [[String: Any]])?.first)

        #expect(Set(object.keys) == ["snapshots", "currentID"])
        #expect(Set(entry.keys) == ["id", "name", "createdAt", "notes", "kind"])
    }

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
