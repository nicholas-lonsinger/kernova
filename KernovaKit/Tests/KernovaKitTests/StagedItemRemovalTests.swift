import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// Removing staged content whatever its depth or modes, and never through a
/// symlink.
@Suite("StagedItemRemoval", .caseScoped)
struct StagedItemRemovalTests {
    private let scratch = TestScratchDirectory(prefix: "staged-removal")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a tree whose paths run past PATH_MAX is removed whole, two directories open at most")
    func deepTreeIsRemoved() throws {
        let root = try makeDirectory("deep")
        let leaf = try makeDeepTree(
            under: root, depth: 8, name: String(repeating: "d", count: 200), contents: Data("x".utf8))
        #expect(leaf.utf8.count > Int(PATH_MAX))

        let volume = InterposedArchiveVolume()
        try StagedItemRemoval.remove(at: root, on: volume)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(volume.mostOpenDirectories <= 2)
        #expect(volume.openDirectoryCount == 0)
    }

    @Test("directories at 0555 and 0000, with contents, are removed")
    func unwritableDirectoriesAreRemoved() throws {
        let root = try makeDirectory("modes")
        let readOnly = root.appendingPathComponent("read-only", isDirectory: true)
        let sealed = readOnly.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: readOnly.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: sealed.appendingPathComponent("b.txt"))
        let emptySealed = root.appendingPathComponent("empty-sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySealed, withIntermediateDirectories: true)
        #expect(chmod(sealed.path, 0) == 0)
        #expect(chmod(readOnly.path, 0o555) == 0)
        #expect(chmod(emptySealed.path, 0) == 0)
        #expect(chmod(root.path, 0o555) == 0)

        try StagedItemRemoval.remove(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a symlink is removed, and what it points at is left alone")
    func symlinksAreNotFollowed() throws {
        let outside = try makeDirectory("outside")
        let kept = outside.appendingPathComponent("kept.txt")
        try Data("kept".utf8).write(to: kept)
        let root = try makeDirectory("tree")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("to-outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("to-file"), withDestinationURL: kept)
        let link = scratch.url.appendingPathComponent("link-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try StagedItemRemoval.remove(at: root)
        try StagedItemRemoval.remove(at: link)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "kept")
    }

    @Test("a single file is removed, and nothing there is reported as missing")
    func fileAndMissingItem() throws {
        let file = scratch.url.appendingPathComponent("file.txt")
        try Data("f".utf8).write(to: file)
        try StagedItemRemoval.remove(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: Errno.noSuchFileOrDirectory) { try StagedItemRemoval.remove(at: file) }
    }
}
