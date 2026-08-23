import Foundation
import Testing

@testable import Kernova

/// Unit tests for `DropPromiseStaging` — where a promise drag's files wait for
/// the guest's pull, which can come long after the drag is over.
@Suite("DropPromiseStaging", .admissionGated)
struct DropPromiseStagingTests {
    /// A temp root of this test's own, so the reclaim never reaches the files
    /// another suite's drop is staging under the shared one.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPromiseStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("each drop gets a directory of its own, empty and ready to write into")
    func eachDropGetsItsOwnDirectory() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = try #require(DropPromiseStaging.makeDropDirectory(tempRoot: tempRoot))
        let second = try #require(DropPromiseStaging.makeDropDirectory(tempRoot: tempRoot))

        #expect(first != second)
        for directory in [first, second] {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    /// The guest serves drops one at a time, so a batch offered several drags ago
    /// may still be waiting to be pulled. Nothing a later drop can see tells a
    /// queued drop from an abandoned one, so staging a new one reclaims nothing.
    @Test("staging a later drop leaves every earlier drop's files alone")
    func stagingLeavesEarlierDropsAlone() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let staged = try (0..<6).map { index -> URL in
            let directory = try #require(DropPromiseStaging.makeDropDirectory(tempRoot: tempRoot))
            let file = directory.appendingPathComponent("promised-\(index).bin")
            try Data("promised".utf8).write(to: file)
            return file
        }

        for file in staged {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("the launch reclaim takes the whole root, and staging rebuilds it")
    func reclaimAllTakesTheWholeRoot() throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let directory = try #require(DropPromiseStaging.makeDropDirectory(tempRoot: tempRoot))
        try Data("promised".utf8).write(to: directory.appendingPathComponent("a.bin"))

        DropPromiseStaging.reclaimAll(tempRoot: tempRoot)
        #expect(
            !FileManager.default.fileExists(
                atPath: DropPromiseStaging.root(tempRoot: tempRoot).path))

        // Reclaiming a root nothing was staged under is the ordinary
        // first-launch case, not a failure.
        DropPromiseStaging.reclaimAll(tempRoot: tempRoot)

        #expect(DropPromiseStaging.makeDropDirectory(tempRoot: tempRoot) != nil)
    }
}
