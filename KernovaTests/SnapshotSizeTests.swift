import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("SnapshotSize Tests", .caseScoped)
struct SnapshotSizeTests {
    private let scratch = TestScratchDirectory(prefix: "SnapshotSizeTests")

    @Test("A clone's size counts everything it holds, and its private bytes only what was written since the clone")
    func cloneCountsItsWholeSizeAndItsPrivateBlocks() throws {
        let original = scratch.url.appendingPathComponent("Original.img")
        let snapshot = scratch.url.appendingPathComponent("Snapshot", isDirectory: true)
        let clone = snapshot.appendingPathComponent("Disk.img")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: original)
        try #require(
            try snapshot.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
                .volumeSupportsFileCloning == true)
        try #require(clonefile(original.path(percentEncoded: false), clone.path(percentEncoded: false), 0) == 0)
        let allocated = try #require(
            try clone.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)

        #expect(
            SnapshotSize.measure(directory: snapshot)
                == SnapshotSize(bytes: UInt64(allocated), privateBytes: 0))

        let written = 1 << 20
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: written))
        try handle.synchronize()
        try handle.close()

        let privateBytes = try #require(SnapshotSize.privateBytes(of: clone))
        #expect(privateBytes == UInt64(written))
        #expect(SnapshotSize.measure(directory: snapshot)?.privateBytes == privateBytes)
        #expect(SnapshotSize.measure(directory: snapshot)?.bytes == UInt64(allocated))
    }

    @Test("A directory that isn't there measures zero")
    func missingDirectoryMeasuresZero() {
        let missing = scratch.url.appendingPathComponent("Missing", isDirectory: true)
        #expect(SnapshotSize.measure(directory: missing) == SnapshotSize(bytes: 0, privateBytes: nil))
    }
}
