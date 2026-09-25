import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `DropPromiseStaging` — where a promise drag's files wait for
/// the guest's pull, which can come long after the drag is over.
@Suite("DropPromiseStaging", .admissionGated)
struct DropPromiseStagingTests {
    private let stagingRoot = TestStagingRoot()

    @Test("each drop gets a directory of its own, empty and ready to write into")
    func eachDropGetsItsOwnDirectory() throws {
        let first = try #require(DropPromiseStaging(root: stagingRoot.root).makeDropDirectory())
        let second = try #require(DropPromiseStaging(root: stagingRoot.root).makeDropDirectory())

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
        let staged = try (0..<6).map { index -> URL in
            let directory = try #require(DropPromiseStaging(root: stagingRoot.root).makeDropDirectory())
            let file = directory.appendingPathComponent("promised-\(index).bin")
            try Data("promised".utf8).write(to: file)
            return file
        }

        for file in staged {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("drop directories live under the process root")
    func dropDirectoriesLiveUnderTheProcessRoot() throws {
        let directory = try #require(DropPromiseStaging(root: stagingRoot.root).makeDropDirectory())

        #expect(directory.deletingLastPathComponent().standardizedFileURL == stagingRoot.root.url.standardizedFileURL)
    }
}
