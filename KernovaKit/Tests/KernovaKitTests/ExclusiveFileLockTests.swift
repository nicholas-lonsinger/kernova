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

    /// Where this test's lock file goes; nothing is created there.
    private func lockFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("file.lock")
    }

    @Test("a held lock refuses a second acquire, from this process too")
    func heldLockRefusesSecondAcquire() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try lockFile()
        let held = try ExclusiveFileLock.tryAcquire(at: url, creating: .exclusively)
        #expect(held != nil)
        #expect(try ExclusiveFileLock.tryAcquire(at: url, creating: .never) == nil)
        withExtendedLifetime(held) {}
    }

    @Test("a lock is released when it is deinitialized")
    func deinitReleases() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try lockFile()
        do {
            let held = try ExclusiveFileLock.tryAcquire(at: url, creating: .exclusively)
            try #require(held != nil)
        }
        #expect(try ExclusiveFileLock.tryAcquire(at: url, creating: .never) != nil)
    }

    @Test("the lock's descriptor is close-on-exec")
    func descriptorIsCloseOnExec() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = try #require(try ExclusiveFileLock.tryAcquire(at: lockFile(), creating: .exclusively))
        #expect(fcntl(held.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("never-create refuses a missing file; exclusive create refuses an existing one")
    func creationModes() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try lockFile()
        #expect(throws: Errno.noSuchFileOrDirectory) {
            _ = try ExclusiveFileLock.tryAcquire(at: url, creating: .never)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #expect(throws: Errno.fileExists) {
            _ = try ExclusiveFileLock.tryAcquire(at: url, creating: .exclusively)
        }
    }
}
