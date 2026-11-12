import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

@Suite("ExclusiveFileLock", .caseScoped)
struct ExclusiveFileLockTests {
    private let scratch = TestScratchDirectory(prefix: "ExclusiveFileLockTests")

    /// An empty file in this test's own directory.
    private func makeFile() throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let url = scratch.url.appendingPathComponent("file")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// An empty directory inside this test's own directory.
    private func makeDirectory() throws -> URL {
        let url = scratch.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The `dup` stands in for the copy a child holds while any thread spawns
    /// it, until its exec closes the copy.
    @Test("release frees the lock while another descriptor still shares its open file description")
    func releaseFreesTheLockDespiteASharedDescriptor() throws {
        let url = try makeFile()
        var shared: Int32 = -1
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: url))
            shared = dup(held.descriptor)
            try #require(shared >= 0)
        }
        defer { close(shared) }
        #expect(try ExclusiveFileLock.tryAcquire(at: url) != nil)
        #expect(try ExclusiveFileLock.isHeld(at: url) == false)
    }

    @Test("the lock's descriptor is close-on-exec")
    func descriptorIsCloseOnExec() throws {
        let held = try #require(try ExclusiveFileLock.tryAcquire(at: makeDirectory()))
        #expect(fcntl(held.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("nothing at the path throws rather than reporting a held lock")
    func missingPathThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            _ = try ExclusiveFileLock.tryAcquire(at: scratch.url.appendingPathComponent("absent"))
        }
        #expect(throws: Errno.noSuchFileOrDirectory) {
            _ = try ExclusiveFileLock.isHeld(at: scratch.url.appendingPathComponent("absent"))
        }
    }
}
