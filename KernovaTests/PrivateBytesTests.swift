import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("PrivateBytes Tests", .caseScoped)
struct PrivateBytesTests {
    private let scratch = TestScratchDirectory(prefix: "PrivateBytesTests")

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

        #expect(PrivateBytes.of(directory: snapshot) == 0)

        let written = 1 << 20
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: written))
        try handle.synchronize()
        try handle.close()

        let privateBytes = try #require(PrivateBytes.of(file: clone))
        #expect(privateBytes == UInt64(written))
        #expect(PrivateBytes.of(directory: snapshot) == privateBytes)
    }

    @Test("A directory that isn't there holds no private bytes")
    func missingDirectoryHoldsNoPrivateBytes() {
        let missing = scratch.url.appendingPathComponent("Missing", isDirectory: true)
        #expect(PrivateBytes.of(directory: missing) == 0)
    }
}
