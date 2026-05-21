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
}
