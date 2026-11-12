import Darwin
import Foundation
import KernovaTestSupport
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
}
