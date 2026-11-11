import Foundation
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("AttachmentFileMonitor", .caseScoped)
@MainActor
struct AttachmentFileMonitorTests {
    private let scratch = TestScratchDirectory(prefix: "kernova-monitor-test")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    private func path(_ name: String) -> String {
        scratch.url.appendingPathComponent(name).path(percentEncoded: false)
    }

    // MARK: - setPaths

    @Test("setPaths diff removes dropped paths from the map")
    func setPathsRemovesDroppedPaths() async throws {
        let a = path("a.iso")
        let b = path("b.iso")
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        FileManager.default.createFile(atPath: b, contents: Data([0]))

        let monitor = AttachmentFileMonitor(hostNotifications: .isolated())
        await monitor.setPaths([a: nil, b: nil])
        #expect(Set(monitor.existsByPath.keys) == [a, b])

        await monitor.setPaths([a: nil])
        #expect(Set(monitor.existsByPath.keys) == [a])
        #expect(monitor.exists(b) == true, "Dropped path falls back to the unwatched default")
    }

    // MARK: - FS event reactivity

    @Test("File deletion in a watched directory flips exists to false")
    func reactsToFileDeletion() async throws {
        let target = path("vanishes.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        let monitor = AttachmentFileMonitor(hostNotifications: .isolated())
        await monitor.setPaths([target: nil])
        #expect(monitor.exists(target) == true)

        try FileManager.default.removeItem(atPath: target)

        try await waitForChange {
            monitor.exists(target) == false
        }
    }

    // MARK: - Re-probe

    /// Probe stub answering `existence` for every requested path and opening no
    /// parent, so `setPaths` installs no watcher.
    ///
    /// That isolates the re-probe path: with no source on the parent, only an
    /// explicit sweep can change a tracked value, which is the sandbox's
    /// situation for an attachment outside the container.
    private func stubProbe(existence: Bool) -> AttachmentFileMonitor.Probe {
        { added, _, _ in
            AttachmentFileMonitor.ProbeResult(
                existence: Dictionary(uniqueKeysWithValues: added.map { ($0, existence) }),
                parentFDs: [:]
            )
        }
    }

    @Test("revalidate overwrites a path already answered as missing")
    func revalidateReprobesAMissingPath() async throws {
        let target = path("reappears.iso")

        let monitor = AttachmentFileMonitor(probe: stubProbe(existence: false), hostNotifications: .isolated())
        await monitor.setPaths([target: nil])
        #expect(monitor.exists(target) == false)

        FileManager.default.createFile(atPath: target, contents: Data([0]))
        monitor.revalidate()

        try await waitForChange {
            monitor.exists(target) == true
        }
    }

    @Test("App activation re-probes every tracked path")
    func appActivationRevalidates() async throws {
        let target = path("vanishes.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        let notifications = HostNotifications.isolated()
        let monitor = AttachmentFileMonitor(
            probe: stubProbe(existence: true), hostNotifications: notifications)
        await monitor.setPaths([target: nil])
        #expect(monitor.exists(target) == true)
        #expect(monitor.watchedParentsForTesting.isEmpty)

        try FileManager.default.removeItem(atPath: target)
        notifications.appDidBecomeActive.post()

        try await waitForChange {
            monitor.exists(target) == false
        }
    }

    // MARK: - Watcher / fd lifecycle

    @Test("Dropping a path cancels its parent watcher and removes it from the watch set")
    func droppingPathTearsDownWatcher() async throws {
        let target = path("target.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        // Compute the parent the same way the monitor does internally
        // (NSString.deletingLastPathComponent) so the string comparison
        // is exact regardless of URL trailing-slash quirks.
        let expectedParent = (target as NSString).deletingLastPathComponent

        let monitor = AttachmentFileMonitor(hostNotifications: .isolated())
        await monitor.setPaths([target: nil])
        #expect(monitor.exists(target) == true)
        #expect(
            monitor.watchedParentsForTesting.contains(expectedParent),
            "Watcher should be installed for the parent directory while the path is tracked"
        )

        // Drop the path. detach() cancels the DispatchSource (which fires
        // setCancelHandler { close(fd) }) and removes the entry from
        // parentSources.
        await monitor.setPaths([:])
        #expect(monitor.existsByPath.isEmpty)
        #expect(
            monitor.watchedParentsForTesting.isEmpty,
            "Watcher should be removed from the watch set when its last path is dropped"
        )
    }
}
