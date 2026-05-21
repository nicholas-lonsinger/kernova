import Foundation
import Testing

@testable import Kernova

@Suite("AttachmentFileMonitor")
@MainActor
struct AttachmentFileMonitorTests {
    // MARK: - Helpers

    /// Creates a fresh temp directory and registers a cleanup with the
    /// returned closure (call from a `defer`).
    private func makeTempDir() throws -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-monitor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }

    private func path(in dir: URL, _ name: String) -> String {
        dir.appendingPathComponent(name).path(percentEncoded: false)
    }

    // MARK: - setPaths

    @Test("setPaths populates existsByPath once it returns for present and missing files")
    func setPathsPopulatesAfterAwait() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }

        let present = path(in: tmp.url, "present.iso")
        FileManager.default.createFile(atPath: present, contents: Data([0]))
        let missing = path(in: tmp.url, "missing.iso")

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([present, missing])

        #expect(monitor.exists(present) == true)
        #expect(monitor.exists(missing) == false)
    }

    @Test("exists defaults to true between calling setPaths and the await returning")
    func existsIsOptimisticDuringProbe() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let missing = path(in: tmp.url, "missing.iso")

        let monitor = AttachmentFileMonitor()
        // Read exists() before setPaths has had a chance to populate.
        #expect(monitor.exists(missing) == true)

        await monitor.setPaths([missing])
        // After the await, the probe has settled and the missing file
        // reads as missing.
        #expect(monitor.exists(missing) == false)
    }

    @Test("exists returns true for paths that have never been set")
    func existsDefaultsToTrueForUnwatched() {
        let monitor = AttachmentFileMonitor()
        #expect(monitor.exists("/not/being/watched") == true)
    }

    @Test("Empty path strings are ignored")
    func emptyPathsAreIgnored() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let present = path(in: tmp.url, "present.iso")
        FileManager.default.createFile(atPath: present, contents: Data([0]))

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([present, ""])

        #expect(monitor.existsByPath.keys.contains("") == false)
        #expect(monitor.exists(present) == true)
    }

    @Test("setPaths diff removes dropped paths from the map")
    func setPathsRemovesDroppedPaths() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let a = path(in: tmp.url, "a.iso")
        let b = path(in: tmp.url, "b.iso")
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        FileManager.default.createFile(atPath: b, contents: Data([0]))

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([a, b])
        #expect(Set(monitor.existsByPath.keys) == [a, b])

        await monitor.setPaths([a])
        #expect(Set(monitor.existsByPath.keys) == [a])
        #expect(monitor.exists(b) == true, "Dropped path falls back to the unwatched default")
    }

    // MARK: - FS event reactivity

    @Test("File creation in a watched directory flips exists to true")
    func reactsToFileCreation() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let target = path(in: tmp.url, "appears.iso")

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([target])
        #expect(monitor.exists(target) == false)

        FileManager.default.createFile(atPath: target, contents: Data([0]))

        try await waitUntil(timeout: .seconds(5)) {
            monitor.exists(target) == true
        }
    }

    @Test("File deletion in a watched directory flips exists to false")
    func reactsToFileDeletion() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let target = path(in: tmp.url, "vanishes.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([target])
        #expect(monitor.exists(target) == true)

        try FileManager.default.removeItem(atPath: target)

        try await waitUntil(timeout: .seconds(5)) {
            monitor.exists(target) == false
        }
    }

    // MARK: - Race coalescing

    @Test("In-flight probe results are discarded when a later setPaths un-requests their paths")
    func inFlightProbeDiscardedOnSupersedingCall() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let a = path(in: tmp.url, "a.iso")
        let b = path(in: tmp.url, "b.iso")
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        FileManager.default.createFile(atPath: b, contents: Data([0]))

        let monitor = AttachmentFileMonitor()

        // Channels that drive deterministic interleaving: the test waits
        // for `probeStarted` after kicking off the first setPaths, then
        // sends on `release` to let the first probe finish.
        let probeStarted = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()

        // Stub probe used only by the first call. Skips fd allocation
        // (parentFDs is empty) so we don't have to manage real fds in
        // the test.
        monitor.probe = { added, _ in
            probeStarted.continuation.yield()
            for await _ in release.stream { break }
            return AttachmentFileMonitor.ProbeResult(
                existence: Dictionary(uniqueKeysWithValues: added.map { ($0, true) }),
                parentFDs: [:]
            )
        }

        // Kick off the first call in the background; it suspends inside
        // the probe waiting on `release`.
        let firstCall = Task { await monitor.setPaths([a]) }
        for await _ in probeStarted.stream { break }

        // Swap to a non-blocking probe and make the superseding call.
        monitor.probe = { added, _ in
            AttachmentFileMonitor.ProbeResult(
                existence: Dictionary(uniqueKeysWithValues: added.map { ($0, true) }),
                parentFDs: [:]
            )
        }
        await monitor.setPaths([b])
        #expect(monitor.exists(b) == true, "Superseding call applies its own probe")

        // Let the first probe complete. Its apply step should drop the
        // result for `a` because `desiredPaths` is now `[b]`.
        release.continuation.yield()
        release.continuation.finish()
        await firstCall.value

        #expect(monitor.exists(a) == true, "Un-desired path returns the unwatched default")
        #expect(
            Set(monitor.existsByPath.keys) == [b],
            "Only the final desired path should be in the map"
        )
    }

    // MARK: - Watcher / fd lifecycle

    @Test("Dropping a path cancels its parent watcher so no further FS events fire")
    func droppingPathTearsDownWatcher() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let target = path(in: tmp.url, "target.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([target])
        #expect(monitor.exists(target) == true)

        // Drop the path. detach() cancels the DispatchSource, which
        // fires its setCancelHandler { close(fd) } and removes the
        // entry from parentSources.
        await monitor.setPaths([])
        #expect(monitor.existsByPath.isEmpty)

        // Mutate the previously-watched directory and wait well past
        // the debounce window. If the watcher had leaked, its handler
        // would re-fire and write back into existsByPath; with the
        // watcher torn down, no such write happens.
        try FileManager.default.removeItem(atPath: target)
        try await Task.sleep(for: .milliseconds(500))

        #expect(
            monitor.existsByPath.isEmpty,
            "No state changes should occur after the path is dropped — the watcher is gone"
        )
        #expect(
            monitor.exists(target) == true,
            "Untracked path falls back to the optimistic default"
        )
    }
}
