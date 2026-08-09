import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardDirectoryArchive")
struct ClipboardDirectoryArchiveTests {
    /// A unique scratch directory removed when the test ends.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("estimatedByteCount sums regular-file sizes only")
    func estimateSumsFiles() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("tree", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("nested".utf8).write(to: sub.appendingPathComponent("b.txt"))
        try fm.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")

        // a.txt (5) + sub/b.txt (6) = 11; dirs and symlinks contribute 0.
        #expect(ClipboardDirectoryArchive.estimatedByteCount(at: root) == 11)
    }

    @Test("estimatedByteCount is 0 for a tree carrying no file bytes")
    func estimateZeroForByteFreeTrees() throws {
        let fm = FileManager.default
        let scratch = try makeScratch()
        defer { try? fm.removeItem(at: scratch) }

        let empty = scratch.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(ClipboardDirectoryArchive.estimatedByteCount(at: empty) == 0)

        // Only subdirectories and zero-byte files: nothing to sum, yet the tree
        // is real and streams intact (ClipboardDirectoryStreamTests).
        let scaffold = scratch.appendingPathComponent("scaffold", isDirectory: true)
        try fm.createDirectory(
            at: scaffold.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data().write(to: scaffold.appendingPathComponent(".keep"))
        try Data().write(to: scaffold.appendingPathComponent("sub/.keep"))
        #expect(ClipboardDirectoryArchive.estimatedByteCount(at: scaffold) == 0)
    }
}
