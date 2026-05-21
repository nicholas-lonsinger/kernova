import Foundation
import Synchronization
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

    /// Stateful probe stub for the race-coalescing test.
    ///
    /// The first call blocks on `release`; every subsequent call returns
    /// immediately. Sharing one probe across the monitor's lifetime lets
    /// `AttachmentFileMonitor` accept it via init injection (as the only
    /// way to install a probe) while still letting the test interleave
    /// two `setPaths` calls deterministically.
    private final class RaceStubProbe: Sendable {
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        let release: AsyncStream<Void>
        private let releaseContinuation: AsyncStream<Void>.Continuation
        /// `true` until the first call consumes it.
        ///
        /// Subsequent calls see `false` and skip the blocking branch.
        private let isFirstCallPending: Mutex<Bool> = Mutex(true)

        init() {
            (self.started, self.startedContinuation) = AsyncStream<Void>.makeStream()
            (self.release, self.releaseContinuation) = AsyncStream<Void>.makeStream()
        }

        var probe: AttachmentFileMonitor.Probe {
            { [self] added, _ in
                let isFirst = self.isFirstCallPending.withLock { pending in
                    let wasFirst = pending
                    pending = false
                    return wasFirst
                }
                if isFirst {
                    self.startedContinuation.yield()
                    for await _ in self.release { break }
                }
                return AttachmentFileMonitor.ProbeResult(
                    existence: Dictionary(uniqueKeysWithValues: added.map { ($0, true) }),
                    parentFDs: [:]
                )
            }
        }

        func releaseFirstProbe() {
            releaseContinuation.yield()
            releaseContinuation.finish()
        }
    }

    @Test("In-flight probe results are discarded when a later setPaths un-requests their paths")
    func inFlightProbeDiscardedOnSupersedingCall() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let a = path(in: tmp.url, "a.iso")
        let b = path(in: tmp.url, "b.iso")
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        FileManager.default.createFile(atPath: b, contents: Data([0]))

        let stub = RaceStubProbe()
        let monitor = AttachmentFileMonitor(probe: stub.probe)

        // Kick off the first call in the background; it suspends inside
        // the probe waiting on `release`.
        let firstCall = Task { await monitor.setPaths([a]) }
        for await _ in stub.started { break }

        // While the first call is parked in its probe, make a superseding
        // call. The stub returns immediately for every non-first call.
        await monitor.setPaths([b])
        #expect(monitor.exists(b) == true, "Superseding call applies its own probe")

        // Let the first probe complete. Its apply step should drop the
        // result for `a` because `desiredPaths` is now `[b]`.
        stub.releaseFirstProbe()
        await firstCall.value

        #expect(monitor.exists(a) == true, "Un-desired path returns the unwatched default")
        #expect(
            Set(monitor.existsByPath.keys) == [b],
            "Only the final desired path should be in the map"
        )
    }

    // MARK: - Watcher / fd lifecycle

    @Test("Dropping a path cancels its parent watcher and removes it from the watch set")
    func droppingPathTearsDownWatcher() async throws {
        let tmp = try makeTempDir()
        defer { tmp.cleanup() }
        let target = path(in: tmp.url, "target.iso")
        FileManager.default.createFile(atPath: target, contents: Data([0]))

        // Compute the parent the same way the monitor does internally
        // (NSString.deletingLastPathComponent) so the string comparison
        // is exact regardless of URL trailing-slash quirks.
        let expectedParent = (target as NSString).deletingLastPathComponent

        let monitor = AttachmentFileMonitor()
        await monitor.setPaths([target])
        #expect(monitor.exists(target) == true)
        #expect(
            monitor.watchedParentsForTesting.contains(expectedParent),
            "Watcher should be installed for the parent directory while the path is tracked"
        )

        // Drop the path. detach() cancels the DispatchSource (which fires
        // setCancelHandler { close(fd) }) and removes the entry from
        // parentSources.
        await monitor.setPaths([])
        #expect(monitor.existsByPath.isEmpty)
        #expect(
            monitor.watchedParentsForTesting.isEmpty,
            "Watcher should be removed from the watch set when its last path is dropped"
        )
    }
}
