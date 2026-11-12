import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

@Suite("ProcessStagingRoot", .caseScoped)
struct ProcessStagingRootTests {
    /// The reclaiming root; siblings made from it stand in for other processes'.
    private let staging = TestStagingRoot()

    /// Claims `root` and writes one file under it.
    private func stageFile(in root: ProcessStagingRoot) throws -> URL {
        let file = root.url.appendingPathComponent("host-vm/staged.bin")
        try root.createDirectory(at: file.deletingLastPathComponent())
        try Data("bytes".utf8).write(to: file)
        return file
    }

    @Test("claiming a root excludes the staging parent, and so everything staged under it, from backups")
    func parentExcludedFromBackups() throws {
        _ = try stageFile(in: staging.root)
        let parent = staging.root.url.deletingLastPathComponent()
        #expect(try parent.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
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

    @Test("a live root removed from outside is re-claimed under the same name, locked, and staged into")
    func removedLiveRootIsReclaimed() throws {
        let file = try stageFile(in: staging.root)
        try FileManager.default.removeItem(at: staging.root.url)

        try staging.root.createDirectory(at: file.deletingLastPathComponent())

        #expect(FileManager.default.fileExists(atPath: staging.root.url.path))
        #expect(try ExclusiveFileLock.tryAcquire(at: staging.root.url) == nil)
        let staged = try ClipboardFileStaging(label: "host-vm", root: staging.root)
            .makeSink(generation: 1, filename: "after.bin").commit()
        #expect(staged.path.hasPrefix(staging.root.url.path + "/"))
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }
}
