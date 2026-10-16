import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardArchive", .caseScoped)
struct ClipboardArchiveTests {
    private let scratch = TestScratchDirectory(prefix: "aar-tests")

    @Test("estimatedByteCount sums regular-file sizes only")
    func estimateSumsFiles() throws {
        let fm = FileManager.default
        let root = scratch.url.appendingPathComponent("tree", isDirectory: true)
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
        #expect(ClipboardArchive.estimatedByteCount(at: root) == 11)
    }
}
