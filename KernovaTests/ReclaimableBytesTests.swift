import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("ReclaimableBytes Tests", .caseScoped)
struct ReclaimableBytesTests {
    private let scratch = TestScratchDirectory(prefix: "ReclaimableBytesTests")

    @Test("A clone counts only the blocks written into it since it was cloned")
    func cloneCountsOnlyItsPrivateBlocks() throws {
        let original = scratch.url.appendingPathComponent("Original.img")
        let snapshot = scratch.url.appendingPathComponent("Snapshot", isDirectory: true)
        let clone = snapshot.appendingPathComponent("Disk.img")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: original)
        try #require(
            try snapshot.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
                .volumeSupportsFileCloning == true)
        try #require(clonefile(original.path(percentEncoded: false), clone.path(percentEncoded: false), 0) == 0)

        #expect(ReclaimableBytes.of(directory: snapshot) == 0)

        let written = 1 << 20
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: written))
        try handle.synchronize()
        try handle.close()

        let privateBytes = try #require(ReclaimableBytes.privateBytes(of: clone))
        #expect(privateBytes == UInt64(written))
        #expect(ReclaimableBytes.of(directory: snapshot) == privateBytes)
    }

    @Test("A directory that isn't there frees nothing")
    func missingDirectoryFreesNothing() {
        let missing = scratch.url.appendingPathComponent("Missing", isDirectory: true)
        #expect(ReclaimableBytes.of(directory: missing) == 0)
    }
}
