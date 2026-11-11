import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMSnapshot Tests", .caseScoped)
struct VMSnapshotTests {
    private func makeSnapshot(
        name: String, offsetSeconds: TimeInterval = 0, notes: String = ""
    ) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds),
            notes: notes, macAddress: nil)
    }

    // MARK: - Ordering

    @Test("Ordered lists snapshots newest first")
    func orderedIsNewestFirst() {
        let older = makeSnapshot(name: "Older")
        let newer = makeSnapshot(name: "Newer", offsetSeconds: 60)
        let manifest = VMSnapshotManifest(snapshots: [older, newer])
        #expect(manifest.ordered.map(\.name) == ["Newer", "Older"])
    }

    // MARK: - Mutation

    @Test("Renaming rewrites only the named snapshot")
    func renameRewritesOne() {
        let first = makeSnapshot(name: "First")
        let second = makeSnapshot(name: "Second", offsetSeconds: 60)
        var manifest = VMSnapshotManifest(snapshots: [first, second])
        manifest.rename(id: first.id, to: "Renamed")
        #expect(manifest.snapshot(id: first.id)?.name == "Renamed")
        #expect(manifest.snapshot(id: second.id)?.name == "Second")
    }

    @Test("Setting notes rewrites only the named snapshot")
    func setNotesRewritesOne() {
        let first = makeSnapshot(name: "First", notes: "before")
        let second = makeSnapshot(name: "Second", offsetSeconds: 60, notes: "untouched")
        var manifest = VMSnapshotManifest(snapshots: [first, second])
        manifest.setNotes(id: first.id, to: "after the update")
        #expect(manifest.snapshot(id: first.id)?.notes == "after the update")
        #expect(manifest.snapshot(id: second.id)?.notes == "untouched")
    }

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

    // MARK: - Copy

    /// A revert commits the snapshot's configuration for either kind
    /// (`VMLibrary.commitRevertedConfiguration`), so both read the settings in
    /// and only the running state sets them apart.
    @Test("Each kind names the settings it puts back, and the running state tells them apart")
    func capturedContentsNamesSettingsForBothKinds() {
        #expect(SnapshotKindCopy.capturedContents(.warm) == "Running state, disks, and settings")
        #expect(SnapshotKindCopy.capturedContents(.cold) == "Disks and settings")
    }

    @Test("Each kind's short label names the state the snapshot captured")
    func stateLabelNamesEachKind() {
        #expect(SnapshotKindCopy.stateLabel(.warm) == "Running state")
        #expect(SnapshotKindCopy.stateLabel(.cold) == "Powered off")
    }
}
