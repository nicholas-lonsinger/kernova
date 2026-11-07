import DeadCodeKit
import Foundation
import Testing

/// A directory of this test's own under the package's `.build`, removed when `body` returns.
private func withScratch(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/test-scratch/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Suite struct PlatformBundleTests {
    private func bundle(_ location: String) -> PlatformBundle {
        let finding = Finding(kind: "struct", name: "S", hints: ["unused"], location: parsed(location), ids: [])
        return PlatformBundle(full: [finding], production: [finding], presence: Presence(keys: [finding.key]))
    }

    /// A finding that moved leaves no presence of the earlier index behind, which would refuse the new report.
    @Test func aRewrittenBundleKeepsNothingOfTheLastOne() throws {
        try withScratch { scratch in
            let directory = scratch.appendingPathComponent("macos")
            try bundle("A.swift:1:6").write(to: directory)
            let moved = bundle("A.swift:2:6")
            try moved.write(to: directory)
            #expect(try PlatformBundle(contentsOf: directory) == moved)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.sorted() == PlatformBundle.files.sorted())
        }
    }

    @Test func aDirectoryHoldingOtherFilesIsNotReplaced() throws {
        try withScratch { scratch in
            let other = scratch.appendingPathComponent("notes.txt")
            try Data("keep".utf8).write(to: other)
            #expect(throws: BundleError.foreignFiles(scratch.path, ["notes.txt"])) {
                try bundle("A.swift:1:6").write(to: scratch)
            }
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }

    @Test func aBundleWithoutItsPresenceDoesNotRead() throws {
        try withScratch { scratch in
            let directory = scratch.appendingPathComponent("macos")
            try bundle("A.swift:1:6").write(to: directory)
            let presence = directory.appendingPathComponent("presence.tsv")
            try FileManager.default.removeItem(at: presence)
            #expect(throws: BundleError.missingFile(presence.path)) {
                try PlatformBundle(contentsOf: directory)
            }
        }
    }
}
