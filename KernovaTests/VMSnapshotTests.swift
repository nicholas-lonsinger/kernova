import Foundation
import Testing

@testable import Kernova

@Suite("VMSnapshot Tests", .admissionGated)
struct VMSnapshotTests {
    private func makeSnapshot(
        name: String, offsetSeconds: TimeInterval = 0, notes: String = ""
    ) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds),
            notes: notes)
    }

    // MARK: - Ordering

    @Test("Ordered lists snapshots newest first")
    func orderedIsNewestFirst() {
        let older = makeSnapshot(name: "Older")
        let newer = makeSnapshot(name: "Newer", offsetSeconds: 60)
        let manifest = VMSnapshotManifest(snapshots: [older, newer])
        #expect(manifest.ordered.map(\.name) == ["Newer", "Older"])
    }

    @Test("An empty manifest reports empty and orders to nothing")
    func emptyManifest() {
        let manifest = VMSnapshotManifest()
        #expect(manifest.isEmpty)
        #expect(manifest.ordered.isEmpty)
        #expect(manifest.currentID == nil)
    }

    // MARK: - Default names

    @Test("The first default name is the bare prefix")
    func defaultNameWhenEmpty() {
        #expect(VMSnapshotManifest().defaultNewName == "Snapshot")
    }

    @Test("A taken default name is suffixed with the next free number")
    func defaultNameAvoidsCollisions() {
        let manifest = VMSnapshotManifest(snapshots: [
            makeSnapshot(name: "Snapshot"), makeSnapshot(name: "Snapshot 2"),
        ])
        #expect(manifest.defaultNewName == "Snapshot 3")
    }

    // MARK: - Mutation

    @Test("Inserting marks the new snapshot current")
    func insertMarksCurrent() {
        var manifest = VMSnapshotManifest(snapshots: [makeSnapshot(name: "First")])
        let added = makeSnapshot(name: "Second", offsetSeconds: 60)
        manifest.insert(added)
        #expect(manifest.snapshots.count == 2)
        #expect(manifest.currentID == added.id)
    }

    @Test("Removing the current snapshot clears the marker")
    func removeClearsCurrentMarker() {
        let snapshot = makeSnapshot(name: "Only")
        var manifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
        manifest.remove(id: snapshot.id)
        #expect(manifest.isEmpty)
        #expect(manifest.currentID == nil)
    }

    @Test("Removing another snapshot leaves the current marker alone")
    func removeKeepsUnrelatedCurrentMarker() {
        let current = makeSnapshot(name: "Current")
        let other = makeSnapshot(name: "Other", offsetSeconds: 60)
        var manifest = VMSnapshotManifest(
            snapshots: [current, other], currentID: current.id)
        manifest.remove(id: other.id)
        #expect(manifest.currentID == current.id)
        #expect(manifest.snapshots.map(\.name) == ["Current"])
    }

    @Test("Renaming rewrites only the named snapshot")
    func renameRewritesOne() {
        let first = makeSnapshot(name: "First")
        let second = makeSnapshot(name: "Second", offsetSeconds: 60)
        var manifest = VMSnapshotManifest(snapshots: [first, second])
        manifest.rename(id: first.id, to: "Renamed")
        #expect(manifest.snapshot(id: first.id)?.name == "Renamed")
        #expect(manifest.snapshot(id: second.id)?.name == "Second")
    }

    @Test("Renaming an unlisted id changes nothing")
    func renameUnknownIsNoOp() {
        let original = VMSnapshotManifest(snapshots: [makeSnapshot(name: "Only")])
        var manifest = original
        manifest.rename(id: UUID(), to: "Renamed")
        #expect(manifest == original)
    }

    // MARK: - Persistence

    @Test("A manifest round-trips through the config JSON coders")
    func manifestRoundTrips() throws {
        let manifest = VMSnapshotManifest(
            snapshots: [
                makeSnapshot(name: "First", notes: "before the update"),
                makeSnapshot(name: "Second", offsetSeconds: 60),
            ],
            currentID: nil)
        let data = try VMConfiguration.makeJSONEncoder().encode(manifest)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMSnapshotManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("A cold snapshot round-trips through the config JSON coders")
    func coldSnapshotRoundTrips() throws {
        var snapshot = makeSnapshot(name: "Before first boot")
        snapshot.kind = .cold
        let manifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)
        let data = try VMConfiguration.makeJSONEncoder().encode(manifest)
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMSnapshotManifest.self, from: data)
        #expect(decoded.snapshots.first?.kind == .cold)
        #expect(decoded == manifest)
    }

    @Test("A manifest entry carrying no kind decodes as a memory-and-disks snapshot")
    func snapshotWithoutKindDecodesWarm() throws {
        let id = UUID()
        let json = """
            {"snapshots":[{"id":"\(id.uuidString)","name":"One",\
            "createdAt":"2026-01-02T03:04:05Z","notes":""}]}
            """
        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            VMSnapshotManifest.self, from: Data(json.utf8))
        #expect(decoded.snapshot(id: id)?.kind == .warm)
    }
}
