import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ProcessStagingRoot", .admissionGated)
struct ProcessStagingRootTests {
    /// The reclaiming root; siblings made from it stand in for other processes'.
    private let staging = TestStagingRoot()

    /// Claims `root` and writes one file under it.
    private func stageFile(in root: ProcessStagingRoot) throws -> URL {
        try root.claim()
        let file = root.url.appendingPathComponent("host-vm/staged.bin")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: file)
        return file
    }

    @Test("a staging root whose lock is held survives reclaim")
    func heldRootSurvivesReclaim() throws {
        let otherProcess = staging.makeSibling()
        let file = try stageFile(in: otherProcess)

        staging.root.reclaimAbandonedRoots()

        #expect(FileManager.default.fileExists(atPath: file.path))
        withExtendedLifetime(otherProcess) {}
    }

    @Test("a staging root whose lock is free is removed")
    func freeRootIsRemoved() throws {
        let abandoned: URL
        do {
            // Deinitializing the root releases its lock, as its process's exit does.
            let exited = staging.makeSibling()
            _ = try stageFile(in: exited)
            abandoned = exited.url
        }

        staging.root.reclaimAbandonedRoots()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("an entry with no lock file is removed")
    func lockLessEntryIsRemoved() throws {
        let leftover = staging.parent.appendingPathComponent("host-vm/\(UUID().uuidString)/x.bin")
        try FileManager.default.createDirectory(
            at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftover)
        let strayFile = staging.parent.appendingPathComponent("stray")
        try Data().write(to: strayFile)

        staging.root.reclaimAbandonedRoots()

        #expect(!FileManager.default.fileExists(atPath: staging.parent.appendingPathComponent("host-vm").path))
        #expect(!FileManager.default.fileExists(atPath: strayFile.path))
    }

    @Test("a hidden entry still being built is left alone")
    func buildingEntrySurvives() throws {
        let lockedBuild = staging.parent.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedBuild, withIntermediateDirectories: true)
        let buildLock = try ExclusiveFileLock.tryAcquire(
            at: lockedBuild.appendingPathComponent(ProcessStagingRoot.lockFileName), creating: .exclusively)
        try #require(buildLock != nil)
        let unlockedBuild = staging.parent.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unlockedBuild, withIntermediateDirectories: true)

        staging.root.reclaimAbandonedRoots()

        #expect(FileManager.default.fileExists(atPath: lockedBuild.path))
        #expect(FileManager.default.fileExists(atPath: unlockedBuild.path))
        withExtendedLifetime(buildLock) {}
    }

    @Test("reclaim leaves the reclaiming root's own files")
    func reclaimKeepsOwnRoot() throws {
        let file = try stageFile(in: staging.root)

        staging.root.reclaimAbandonedRoots()

        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a claim publishes the root under its name only with its lock held")
    func claimPublishesLockedRoot() throws {
        try staging.root.claim()
        try staging.root.claim()

        let lockFile = staging.root.url.appendingPathComponent(ProcessStagingRoot.lockFileName)
        #expect(FileManager.default.fileExists(atPath: lockFile.path))
        #expect(try ExclusiveFileLock.tryAcquire(at: lockFile, creating: .never) == nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: staging.parent.path)
        #expect(entries == [staging.root.url.lastPathComponent])
    }
}
