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

    @Test("a live root removed from outside is re-claimed under the same name, locked, and staged into")
    func removedLiveRootIsReclaimed() throws {
        let file = try stageFile(in: staging.root)
        try FileManager.default.removeItem(at: staging.root.url)

        try staging.root.createDirectory(at: file.deletingLastPathComponent())

        #expect(FileManager.default.fileExists(atPath: staging.root.url.path))
        #expect(try ExclusiveFileLock.tryAcquire(at: staging.root.url) == nil)
        let staged = try ClipboardFileStaging(label: "host-vm", root: staging.root)
            .reserveScratchDirectory(generation: 1)
        #expect(staged.path.hasPrefix(staging.root.url.path + "/"))
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }
}
