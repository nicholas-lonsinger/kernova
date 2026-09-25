import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// `ExclusiveFileLock` on a directory, run inside the sandboxed app test host,
/// where `ProcessStagingRoot` locks its staging roots.
@Suite("ExclusiveFileLock in the sandboxed host", .admissionGated)
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
}
