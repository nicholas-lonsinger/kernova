import Foundation
import Testing

@testable import Kernova

@Suite("VMSnapshotStore Tests", .admissionGated)
struct VMSnapshotStoreTests {
    /// A throwaway bundle directory holding the files a snapshot captures.
    private struct Fixture {
        let bundleURL: URL
        let layout: VMBundleLayout
        var configuration: VMConfiguration
    }

    private func makeFixture(
        additionalDiskID: UUID? = nil,
        externalDiskPath: String? = nil,
        includeAuxiliaryStorage: Bool = true
    ) throws -> Fixture {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let layout = VMBundleLayout(bundleURL: bundleURL)

        try Data("main-disk".utf8).write(to: layout.diskImageURL)
        // Identity files a revert must never write back.
        try Data("hardware".utf8).write(to: layout.hardwareModelURL)
        try Data("machine".utf8).write(to: layout.machineIdentifierURL)
        if includeAuxiliaryStorage {
            try Data("aux".utf8).write(to: layout.auxiliaryStorageURL)
        }

        var config = VMConfiguration(name: "Snapshot VM", guestOS: .macOS, bootMode: .macOS)
        var disks = [StorageDisk(path: "Disk.asif", isInternal: true)]
        if let additionalDiskID {
            try FileManager.default.createDirectory(
                at: layout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
            try Data("extra-disk".utf8).write(to: layout.additionalDiskURL(id: additionalDiskID))
            disks.append(
                StorageDisk(
                    id: additionalDiskID,
                    path: "AdditionalDisks/\(additionalDiskID.uuidString).asif",
                    isInternal: true))
        }
        if let externalDiskPath {
            disks.append(StorageDisk(path: externalDiskPath))
        }
        config.storageDisks = disks
        return Fixture(bundleURL: bundleURL, layout: layout, configuration: config)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.bundleURL)
    }

    private func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Captured payload

    @Test("Capture covers the in-bundle disks and the firmware state")
    func capturedPathsCoverMutableBundleFiles() throws {
        let extraID = UUID()
        let fixture = try makeFixture(additionalDiskID: extraID)
        defer { cleanUp(fixture) }

        let paths = VMSnapshotStore.capturedRelativePaths(
            for: fixture.configuration, layout: fixture.layout)
        #expect(paths.contains("Disk.asif"))
        #expect(paths.contains("AdditionalDisks/\(extraID.uuidString).asif"))
        #expect(paths.contains("AuxiliaryStorage"))
    }

    @Test("Capture skips external disks and the VM's identity files")
    func capturedPathsSkipExternalsAndIdentity() throws {
        let fixture = try makeFixture(externalDiskPath: "/Volumes/Elsewhere/Extra.asif")
        defer { cleanUp(fixture) }

        let paths = VMSnapshotStore.capturedRelativePaths(
            for: fixture.configuration, layout: fixture.layout)
        #expect(!paths.contains("/Volumes/Elsewhere/Extra.asif"))
        #expect(!paths.contains("HardwareModel"))
        #expect(!paths.contains("MachineIdentifier"))
    }

    @Test("A VM with no configured disks still captures its main disk")
    func capturedPathsFallBackToTheMainDisk() throws {
        var fixture = try makeFixture(includeAuxiliaryStorage: false)
        defer { cleanUp(fixture) }
        fixture.configuration.storageDisks = nil

        let paths = VMSnapshotStore.capturedRelativePaths(
            for: fixture.configuration, layout: fixture.layout)
        #expect(paths == ["Disk.asif"])
    }

    // MARK: - Manifest

    @Test("A bundle with no manifest reads as empty")
    func missingManifestReadsEmpty() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        #expect(VMSnapshotStore().loadManifest(bundleURL: fixture.bundleURL).isEmpty)
    }

    @Test("A saved manifest reads back")
    func manifestRoundTrips() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        // A whole-second date: the shared config coders write ISO-8601, whose
        // precision is the second.
        let snapshot = VMSnapshot(
            name: "Before the update", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "tools configured")
        let manifest = VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id)

        try store.saveManifest(manifest, bundleURL: fixture.bundleURL)

        #expect(store.loadManifest(bundleURL: fixture.bundleURL) == manifest)
    }

    @Test("A corrupt manifest reads as empty rather than throwing")
    func corruptManifestReadsEmpty() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try FileManager.default.createDirectory(
            at: fixture.layout.snapshotsDirectoryURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.layout.snapshotManifestURL)

        #expect(VMSnapshotStore().loadManifest(bundleURL: fixture.bundleURL).isEmpty)
    }

    // MARK: - Capture and restore

    @Test("Capture copies every named file into the snapshot's directory")
    func captureCopiesFiles() throws {
        let extraID = UUID()
        let fixture = try makeFixture(additionalDiskID: extraID)
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)

        let snapshotLayout = fixture.layout.snapshotLayout(id: snapshotID)
        #expect(prepared.saveFileURL == snapshotLayout.saveFileURL)
        #expect(contents(of: snapshotLayout.diskImageURL) == "main-disk")
        #expect(contents(of: snapshotLayout.additionalDiskURL(id: extraID)) == "extra-disk")
        #expect(contents(of: snapshotLayout.auxiliaryStorageURL) == "aux")
    }

    @Test("Capture reports a file that is not in the bundle")
    func captureReportsMissingSource() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()
        _ = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)

        #expect(throws: VMSnapshotError.self) {
            try store.captureDisks(
                bundleURL: fixture.bundleURL, snapshotID: snapshotID,
                relativePaths: ["Nowhere.asif"])
        }
    }

    @Test("Restore writes the captured state back and keeps the snapshot's copies")
    func restoreWritesBackAndKeepsTheSnapshot() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        // The guest moves on, and the suspend slot holds something else.
        try Data("diverged".utf8).write(to: fixture.layout.diskImageURL)
        try Data("stale-suspend".utf8).write(to: fixture.layout.saveFileURL)

        let plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        try store.restore(bundleURL: fixture.bundleURL, snapshotID: snapshotID, plan: plan)

        #expect(contents(of: fixture.layout.diskImageURL) == "main-disk")
        #expect(contents(of: fixture.layout.saveFileURL) == "saved-state")
        // Still revertible a second time.
        #expect(contents(of: fixture.layout.snapshotLayout(id: snapshotID).saveFileURL) == "saved-state")
    }

    @Test("Restore refuses a snapshot missing its saved state")
    func restoreRefusesAnIncompleteSnapshot() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()
        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)

        #expect(throws: VMSnapshotError.self) {
            _ = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        }
        // Nothing was written over.
        #expect(contents(of: fixture.layout.diskImageURL) == "main-disk")
    }

    @Test("A capture records the configuration it was taken under")
    func captureRecordsTheConfiguration() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()
        var configuration = fixture.configuration
        configuration.memorySizeInGB = 8

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, configuration: configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        let plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        #expect(plan.configuration.memorySizeInGB == 8)
    }

    @Test("The restore plan lists what the snapshot captured, not what the VM configures now")
    func planListsTheCapturedDisks() throws {
        let extraID = UUID()
        let fixture = try makeFixture(additionalDiskID: extraID)
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        let plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        #expect(plan.relativePaths.contains("AdditionalDisks/\(extraID.uuidString).asif"))
        #expect(plan.relativePaths.contains("AuxiliaryStorage"))
    }

    @Test("A snapshot with no recorded configuration is refused")
    func planRefusesASnapshotWithoutAConfiguration() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()
        let snapshotLayout = fixture.layout.snapshotLayout(id: snapshotID)
        try FileManager.default.createDirectory(
            at: snapshotLayout.bundleURL, withIntermediateDirectories: true)
        try Data("saved-state".utf8).write(to: snapshotLayout.saveFileURL)

        #expect(throws: VMSnapshotError.self) {
            _ = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        }
    }

    @Test("Restore writes the plan's configuration into the bundle")
    func restoreWritesTheConfiguration() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        var plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        plan.configuration.memorySizeInGB = 12
        try store.restore(bundleURL: fixture.bundleURL, snapshotID: snapshotID, plan: plan)

        let written = try VMConfiguration.load(fromBundle: fixture.bundleURL)
        #expect(written.memorySizeInGB == 12)
    }

    // MARK: - Removal and sizes

    @Test("Discarding a snapshot trashes its directory")
    func discardTrashesTheDirectory() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let fileSystem = MockFileSystem()
        let store = VMSnapshotStore(fileSystem: fileSystem)
        let snapshotID = UUID()
        _ = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)

        try store.discardSnapshot(bundleURL: fixture.bundleURL, snapshotID: snapshotID)

        #expect(
            fileSystem.trashedURLs == [fixture.layout.snapshotDirectoryURL(id: snapshotID)])
    }

    @Test("Discarding a snapshot with nothing on disk trashes nothing")
    func discardOfAMissingDirectoryIsANoOp() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let fileSystem = MockFileSystem()
        let store = VMSnapshotStore(fileSystem: fileSystem)

        try store.discardSnapshot(bundleURL: fixture.bundleURL, snapshotID: UUID())

        #expect(fileSystem.trashedURLs.isEmpty)
    }

    @Test("Cleaning up a partial capture removes its directory outright")
    func removeSnapshotDirectoryDeletes() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let snapshotID = UUID()
        _ = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)

        store.removeSnapshotDirectory(bundleURL: fixture.bundleURL, snapshotID: snapshotID)

        let directory = fixture.layout.snapshotDirectoryURL(id: snapshotID)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    @Test("On-disk sizes count the captured files")
    func onDiskBytesCountsCapturedFiles() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let store = VMSnapshotStore()
        let captured = UUID()
        let empty = UUID()
        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: captured,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: captured,
            relativePaths: prepared.relativePaths)

        let sizes = store.onDiskBytes(
            bundleURL: fixture.bundleURL, snapshotIDs: [captured, empty])

        #expect((sizes[captured] ?? 0) > 0)
        #expect(sizes[empty] == 0)
    }
}
