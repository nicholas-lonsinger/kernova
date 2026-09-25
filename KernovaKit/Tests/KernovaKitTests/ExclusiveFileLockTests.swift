import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

@Suite("ExclusiveFileLock", .admissionGated)
struct ExclusiveFileLockTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ExclusiveFileLockTests-\(UUID().uuidString)", isDirectory: true)

    /// An empty file in this test's own directory.
    private func makeFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("file")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// An empty directory inside this test's own directory.
    private func makeDirectory() throws -> URL {
        let url = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a held lock on a file refuses a second acquire from this process, until released")
    func fileLockRefusesSecondUntilReleased() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeDirectory()
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: url))
            let second = try ExclusiveFileLock.tryAcquire(at: url)
            #expect(second == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.tryAcquire(at: url) != nil)
    }

    @Test("the lock's descriptor is close-on-exec")
    func descriptorIsCloseOnExec() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = try #require(try ExclusiveFileLock.tryAcquire(at: makeDirectory()))
        #expect(fcntl(held.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("nothing at the path throws rather than reporting a held lock")
    func missingPathThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            _ = try ExclusiveFileLock.tryAcquire(at: directory.appendingPathComponent("absent"))
        }
    }
}
