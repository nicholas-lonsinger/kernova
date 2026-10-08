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

    @Test("a held lock on a file refuses a second acquire from this process, until released")
    func fileLockRefusesSecondUntilReleased() throws {
        let url = try makeFile()
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: url))
            let second = try ExclusiveFileLock.tryAcquire(at: url)
            #expect(second == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.tryAcquire(at: url) != nil)
    }

    @Test("a held lock on a directory refuses a second acquire from this process, until released")
    func directoryLockRefusesSecondUntilReleased() throws {
        let url = try makeDirectory()
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: url))
            let second = try ExclusiveFileLock.tryAcquire(at: url)
            #expect(second == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.tryAcquire(at: url) != nil)
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

    @Test("a creating acquire makes an absent file owner-only, and refuses a second until released")
    func creatingAcquireCreatesAndLocks() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let url = scratch.url.appendingPathComponent("created.lock")
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(creatingFileAt: url))
            #expect(try ExclusiveFileLock.tryAcquire(creatingFileAt: url) == nil)
            #expect(try ExclusiveFileLock.tryAcquire(at: url) == nil)
            #expect(fcntl(held.descriptor, F_GETFD) & FD_CLOEXEC != 0)
            withExtendedLifetime(held) {}
        }
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == S_IRUSR | S_IWUSR)
        #expect(try ExclusiveFileLock.tryAcquire(creatingFileAt: url) != nil)
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

    @Test("isHeld reports a directory's lock while it is held, across a rename, and not after")
    func isHeldFollowsTheLockAcrossARename() throws {
        let url = try makeDirectory()
        let renamed = scratch.url.appendingPathComponent("renamed", isDirectory: true)
        #expect(try ExclusiveFileLock.isHeld(at: url) == false)
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: url))
            #expect(try ExclusiveFileLock.isHeld(at: url))
            try FileManager.default.moveItem(at: url, to: renamed)
            #expect(try ExclusiveFileLock.isHeld(at: renamed))
            #expect(try ExclusiveFileLock.tryAcquire(at: renamed) == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.isHeld(at: renamed) == false)
    }
}
