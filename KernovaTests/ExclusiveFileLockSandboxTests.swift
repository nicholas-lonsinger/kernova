import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// `ExclusiveFileLock` on a directory, run inside the sandboxed app test host,
/// where `ProcessStagingRoot` locks its staging roots.
@Suite("ExclusiveFileLock in the sandboxed host", .caseScoped)
struct ExclusiveFileLockSandboxTests {
    private let staging = TestStagingRoot()

    @Test("a locked directory refuses a second lock until the first is released")
    func directoryLockRefusesSecondUntilReleased() throws {
        let directory = staging.parent.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: directory))
            let second = try ExclusiveFileLock.tryAcquire(at: directory)
            #expect(second == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.tryAcquire(at: directory) != nil)
    }

    @Test("isHeld reports a locked directory while the lock is held, and not after")
    func isHeldFollowsTheLock() throws {
        let directory = staging.parent.appendingPathComponent("probed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(try ExclusiveFileLock.isHeld(at: directory) == false)
        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(at: directory))
            #expect(try ExclusiveFileLock.isHeld(at: directory))
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.isHeld(at: directory) == false)
    }

    /// The shape `AppCopyClaim` takes on its lock file.
    @Test("a creating acquire makes and locks an absent file, refusing a second until released")
    func creatingAcquireRefusesSecondUntilReleased() throws {
        try FileManager.default.createDirectory(at: staging.parent, withIntermediateDirectories: true)
        let file = staging.parent.appendingPathComponent("created.lock", isDirectory: false)

        do {
            let held = try #require(try ExclusiveFileLock.tryAcquire(creatingFileAt: file))
            let second = try ExclusiveFileLock.tryAcquire(creatingFileAt: file)
            #expect(second == nil)
            withExtendedLifetime(held) {}
        }
        #expect(try ExclusiveFileLock.tryAcquire(creatingFileAt: file) != nil)
    }
}
