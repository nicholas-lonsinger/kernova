import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMBundleMachineFiles Tests", .caseScoped)
struct VMBundleMachineFilesTests {
    private let scratch = TestScratchDirectory(prefix: "BundleMachineFilesTests")

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
        let bundleURL = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let layout = VMBundleLayout(bundleURL: bundleURL)

        try Data("main-disk".utf8).write(to: layout.diskImageURL)
        // Identity files a revert must never write back.
        try Data("hardware".utf8).write(to: layout.hardwareModelURL)
        try Data("machine".utf8).write(to: layout.machineIdentifierURL)
        if includeAuxiliaryStorage {
            try Data("aux".utf8).write(to: layout.auxiliaryStorageURL)
        }

        var config = VMConfiguration(
            name: "Snapshot VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        var disks = [StorageDisk(path: "Disk.asif", isInternal: true)]
        if let additionalDiskID {
            try FileManager.default.createDirectory(
                at: layout.bundleURL.appendingPathComponent("AdditionalDisks"), withIntermediateDirectories: true)
            try Data("extra-disk".utf8).write(
                to: layout.bundleURL.appendingPathComponent("AdditionalDisks/\(additionalDiskID.uuidString).asif"))
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

    /// Stages `plan` and installs it, the two steps a revert runs around the
    /// configuration commit that is not this store's job.
    private func restore(
        with store: VMBundleMachineFiles, _ fixture: Fixture, snapshotID: UUID, plan: VMSnapshotRestorePlan
    ) throws {
        try store.stageRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID, plan: plan)
        try store.installRestore(bundleURL: fixture.bundleURL, plan: plan)
    }

    private func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Capture and restore

    @Test("A restore that fails partway leaves the bundle exactly as it was")
    func failedRestoreLeavesTheBundleUntouched() throws {
        let fixture = try makeFixture()
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        // The guest moved on since the capture, so every bundle file the revert
        // would write differs from the snapshot's copy.
        try Data("diverged".utf8).write(to: fixture.layout.diskImageURL)
        try Data("diverged-aux".utf8).write(to: fixture.layout.auxiliaryStorageURL)
        try Data("stale-suspend".utf8).write(to: fixture.layout.saveFileURL)

        // A plan naming a file the snapshot does not hold — the failure a
        // filesystem error mid-revert produces, made deterministic.
        let plan = VMSnapshotRestorePlan(
            configuration: fixture.configuration,
            relativePaths: ["Disk.asif", "AuxiliaryStorage", "Nowhere.asif"], kind: .warm)
        #expect(throws: (any Error).self) {
            try restore(with: store, fixture, snapshotID: snapshotID, plan: plan)
        }

        #expect(contents(of: fixture.layout.diskImageURL) == "diverged")
        #expect(contents(of: fixture.layout.auxiliaryStorageURL) == "diverged-aux")
        #expect(contents(of: fixture.layout.saveFileURL) == "stale-suspend")
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.restoreStagingURL.path(percentEncoded: false)))
    }

    @Test("A restore that fails while swapping drops the bundle's stale saved state")
    func failedCommitDropsTheStaleSaveFile() throws {
        let extraID = UUID()
        let fixture = try makeFixture(additionalDiskID: extraID)
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)
        try Data("stale-suspend".utf8).write(to: fixture.layout.saveFileURL)

        // A destination directory that refuses the rename: the commit is renames
        // only, so this is the failure a full volume produces there.
        let locked = fixture.bundleURL.appendingPathComponent("AdditionalDisks").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked)
        }

        let plan = VMSnapshotRestorePlan(
            configuration: fixture.configuration,
            relativePaths: ["AdditionalDisks/\(extraID.uuidString).asif"], kind: .warm)
        #expect(throws: (any Error).self) {
            try restore(with: store, fixture, snapshotID: snapshotID, plan: plan)
        }

        // The suspend slot describes the guest RAM belonging to the disks this
        // revert was replacing, so a resume offered from it could only be wrong.
        #expect(!fixture.layout.hasSaveFile)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.restoreStagingURL.path(percentEncoded: false)))
    }

    // MARK: - Cold snapshots

    @Test("A revert to a snapshot taken while stopped writes the disks back and clears the bundle's suspend slot")
    func coldRestoreDropsTheSuspendSlot() throws {
        let fixture = try makeFixture()
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()
        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)

        // The VM ran and suspended since the capture.
        try Data("diverged".utf8).write(to: fixture.layout.diskImageURL)
        try Data("stale-suspend".utf8).write(to: fixture.layout.saveFileURL)

        let plan = try store.planRestore(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, kind: .cold)
        try restore(with: store, fixture, snapshotID: snapshotID, plan: plan)

        #expect(contents(of: fixture.layout.diskImageURL) == "main-disk")
        #expect(!fixture.layout.hasSaveFile)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.restoreStagingURL.path(percentEncoded: false)))
    }

    /// Moves the bundle's `file` out of the bundle and leaves a symbolic link
    /// to it in its place, answering where the file went.
    private func moveOutAndLink(_ file: URL) throws -> URL {
        let target = scratch.url.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        return target
    }

    @Test("Capturing a bundle whose disk or suspend slot is a symbolic link is refused, naming the link")
    func captureOfLinkedFilesIsRefused() throws {
        let fixture = try makeFixture()
        try Data("suspended".utf8).write(to: fixture.layout.saveFileURL)
        _ = try moveOutAndLink(fixture.layout.diskImageURL)
        _ = try moveOutAndLink(fixture.layout.saveFileURL)
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()
        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, configuration: fixture.configuration)

        #expect(throws: VMBundleItems.SymbolicLinkError(url: fixture.layout.diskImageURL)) {
            try store.captureDisks(
                bundleURL: fixture.bundleURL, snapshotID: snapshotID, relativePaths: prepared.relativePaths)
        }
        #expect(throws: VMBundleItems.SymbolicLinkError(url: fixture.layout.saveFileURL)) {
            try store.captureSuspendSlot(bundleURL: fixture.bundleURL, snapshotID: snapshotID)
        }
    }

    @Test("A revert replaces a disk the bundle now holds as a symbolic link, leaving the link's target as it was")
    func revertReplacesALinkedDisk() throws {
        let fixture = try makeFixture()
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()
        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, relativePaths: prepared.relativePaths)

        // Since the capture the disk was moved out behind a link, and the VM ran.
        let moved = try moveOutAndLink(fixture.layout.diskImageURL)
        try Data("diverged".utf8).write(to: moved)

        let plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID, kind: .cold)
        try restore(with: store, fixture, snapshotID: snapshotID, plan: plan)

        #expect(contents(of: fixture.layout.diskImageURL) == "main-disk")
        #expect(
            try fixture.layout.diskImageURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(contents(of: moved) == "diverged")
    }

    @Test("The restore plan lists what the snapshot captured, not what the VM configures now")
    func planListsTheCapturedDisks() throws {
        let extraID = UUID()
        let fixture = try makeFixture(additionalDiskID: extraID)
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let snapshotID = UUID()

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        try Data("saved-state".utf8).write(to: prepared.saveFileURL)

        let plan = try store.planRestore(bundleURL: fixture.bundleURL, snapshotID: snapshotID, kind: .warm)
        #expect(plan.relativePaths.contains("AdditionalDisks/\(extraID.uuidString).asif"))
        #expect(plan.relativePaths.contains("AuxiliaryStorage"))
    }

    @Test("A snapshot neither captures the host state nor writes it back")
    func hostStateStaysOutOfSnapshots() throws {
        let fixture = try makeFixture()
        let store = VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles())
        let files = VMStagedBundle.fixtureForTesting(
            at: fixture.bundleURL, access: CoordinatedBundleFileAccess())
        let snapshotID = UUID()
        try files.update(.hostState) { $0.displayPreference = .fullscreen }

        let prepared = try store.prepareSnapshot(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            configuration: fixture.configuration)
        try store.captureDisks(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID,
            relativePaths: prepared.relativePaths)
        let edited = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .fullscreen,
            agentInstallNudgeDismissed: true)
        try files.update(.hostState) { $0 = edited }

        let plan = try store.planRestore(
            bundleURL: fixture.bundleURL, snapshotID: snapshotID, kind: .cold)
        try restore(with: store, fixture, snapshotID: snapshotID, plan: plan)

        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.snapshotDirectoryURL(id: snapshotID)
                    .appendingPathComponent("host-state.json").path(percentEncoded: false)))
        // A change that moves nothing answers what the file holds.
        #expect(try files.update(.hostState) { _ in } == edited)
    }
}
