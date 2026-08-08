import Foundation
import Testing

@testable import KernovaKit

@Suite("ClipboardFileStaging")
struct ClipboardFileStagingTests {
    /// A fresh staging instance rooted in a unique temp directory.
    private func makeStaging(
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "test-\(UUID().uuidString)",
            tempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true),
            freeSpaceProvider: freeSpaceProvider
        )
    }

    @Test("a sink writes streamed chunks and commit keeps the file with the right name")
    func sinkWritesAndCommits() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "photo.png")
        try sink.write(Data([0x89, 0x50]))
        try sink.write(Data([0x4E, 0x47]))
        let url = try sink.commit()

        #expect(url.lastPathComponent == "photo.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("abort deletes the partial file")
    func abortDeletesPartial() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "partial.bin")
        try sink.write(Data([1, 2, 3]))
        let url = sink.url
        #expect(FileManager.default.fileExists(atPath: url.path))

        sink.abort()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the last 3 generations survive; a 4th evicts only the oldest")
    func keepsGenerationHistory() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        var dirs: [URL] = []
        for generation in 1...4 {
            let sink = try staging.makeSink(
                generation: UInt64(generation), filename: "g\(generation).bin")
            try sink.write(Data([UInt8(generation)]))
            try sink.commit()
            dirs.append(sink.url.deletingLastPathComponent())
        }

        // Generation 1's directory was evicted when generation 4 arrived; 2–4 survive.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[2].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }

    @Test("sinks for the same generation share one directory")
    func sameGenerationSharesDirectory() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let a = try staging.makeSink(generation: 7, filename: "a.bin")
        let b = try staging.makeSink(generation: 7, filename: "b.bin")
        try a.commit()
        try b.commit()
        #expect(a.url.deletingLastPathComponent() == b.url.deletingLastPathComponent())
    }

    @Test("same-named sinks in one generation get distinct, non-colliding URLs")
    func sameNameSinksDeduped() throws {
        // A multi-file copy can carry two payloads that share a name; the second
        // sink must not reuse the first's path (which would collapse them).
        let staging = makeStaging()
        defer { staging.sweep() }

        let a = try staging.makeSink(generation: 1, filename: "dup.txt")
        try a.write(Data("first".utf8))
        let b = try staging.makeSink(generation: 1, filename: "dup.txt")
        try b.write(Data("second".utf8))
        let urlA = try a.commit()
        let urlB = try b.commit()

        #expect(urlA != urlB)
        #expect(urlA.lastPathComponent == "dup.txt")
        #expect(urlB.lastPathComponent == "dup (2).txt")
        #expect(try Data(contentsOf: urlA) == Data("first".utf8))
        #expect(try Data(contentsOf: urlB) == Data("second".utf8))
    }

    @Test("sweep removes the staging root")
    func sweepRemovesRoot() throws {
        let staging = makeStaging()
        let sink = try staging.makeSink(generation: 1, filename: "x.bin")
        try sink.commit()
        let dir = sink.url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))

        staging.sweep()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("roots nest under one shared parent, one child per label")
    func rootsNestUnderSharedParent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let staging = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)
        let sink = try staging.makeSink(generation: 1, filename: "x.bin")
        try sink.commit()

        let parent = tempRoot.appendingPathComponent(
            ClipboardFileStaging.parentDirectoryName, isDirectory: true)
        let labelRoot = parent.appendingPathComponent("host-vm", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: labelRoot.path))
        #expect(sink.url.path.hasPrefix(labelRoot.path + "/"))
    }

    @Test("same-generation roots of two labels never share a directory; one sweep leaves the other")
    func perLabelRootsAreDisjoint() throws {
        // Every label's counter starts at 1, so the same generation number must
        // land in different roots.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let receive = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)
        let drops = ClipboardFileStaging(label: "host-drops-vm", tempRoot: tempRoot)

        let received = try receive.makeSink(generation: 1, filename: "in.bin")
        try received.write(Data("in".utf8))
        try received.commit()
        let dropped = try drops.makeSink(generation: 1, filename: "out.bin")
        try dropped.write(Data("out".utf8))
        try dropped.commit()

        #expect(
            received.url.deletingLastPathComponent() != dropped.url.deletingLastPathComponent())
        // A sibling label extending this one is not "inside" this root.
        #expect(!receive.isInStagingRoot(dropped.url))

        // Sweeping one root leaves the other's file intact.
        drops.sweep()
        #expect(!FileManager.default.fileExists(atPath: dropped.url.path))
        #expect(FileManager.default.fileExists(atPath: received.url.path))
    }

    @Test("same-label instances from different sessions own disjoint roots; one's sweep leaves the other's files")
    func sameLabelInstancesAreDisjoint() throws {
        // A VM restart mints a fresh staging instance under the same label; its
        // sweeps must never delete the previous session's files, which can still
        // back URLs on the pasteboard.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let previousSession = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)
        let nextSession = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)

        let kept = try previousSession.makeSink(generation: 1, filename: "kept.bin")
        try kept.write(Data("kept".utf8))
        try kept.commit()
        let swept = try nextSession.makeSink(generation: 1, filename: "swept.bin")
        try swept.commit()

        #expect(kept.url.deletingLastPathComponent() != swept.url.deletingLastPathComponent())
        #expect(!nextSession.isInStagingRoot(kept.url))

        nextSession.sweep()
        #expect(!FileManager.default.fileExists(atPath: swept.url.path))
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
    }

    @Test("reclaimSiblingRoots removes earlier same-label roots, leaving its own and other labels")
    func reclaimSiblingRootsScopesToLabel() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let previousSession = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)
        let liveSession = ClipboardFileStaging(label: "host-vm", tempRoot: tempRoot)
        let otherLabel = ClipboardFileStaging(label: "host-other", tempRoot: tempRoot)

        let orphan = try previousSession.makeSink(generation: 1, filename: "orphan.bin")
        try orphan.commit()
        let kept = try liveSession.makeSink(generation: 1, filename: "kept.bin")
        try kept.commit()
        let unrelated = try otherLabel.makeSink(generation: 1, filename: "unrelated.bin")
        try unrelated.commit()

        liveSession.reclaimSiblingRoots()

        #expect(!FileManager.default.fileExists(atPath: orphan.url.path))
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.url.path))
    }

    @Test("reclaimAll removes every label family under the shared parent")
    func reclaimAllSweepsEveryFamily() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        // Crash leftovers from every family the host mints.
        for label in ["host", "host-vm", "host-send-vm"] {
            let staging = ClipboardFileStaging(label: label, tempRoot: tempRoot)
            let sink = try staging.makeSink(generation: 1, filename: "orphan.bin")
            try sink.commit()
        }
        let parent = tempRoot.appendingPathComponent(
            ClipboardFileStaging.parentDirectoryName, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: parent.path))

        ClipboardFileStaging.reclaimAll(tempRoot: tempRoot)
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }

    @Test("hasCapacity reflects the injected free-space provider")
    func freeSpaceGuard() {
        let tightStaging = makeStaging(freeSpaceProvider: { _ in 10 * 1024 * 1024 })  // 10 MiB
        defer { tightStaging.sweep() }
        // 1 MiB + the default 64 MiB margin exceeds 10 MiB → no capacity.
        #expect(!tightStaging.hasCapacity(forByteCount: 1 * 1024 * 1024))
        // With no margin, 1 MiB fits in 10 MiB.
        #expect(tightStaging.hasCapacity(forByteCount: 1 * 1024 * 1024, margin: 0))

        let roomyStaging = makeStaging(freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })  // 100 GiB
        defer { roomyStaging.sweep() }
        #expect(roomyStaging.hasCapacity(forByteCount: 1 * 1024 * 1024 * 1024))  // 1 GiB fits

        let unknownStaging = makeStaging(freeSpaceProvider: { _ in nil })
        defer { unknownStaging.sweep() }
        // Unknown capacity is treated as "fits" — never block on a failed query.
        #expect(unknownStaging.hasCapacity(forByteCount: Int.max - ClipboardStreamTuning.freeSpaceMargin))
    }

    @Test("a byte count whose margined total leaves Int64 does not fit — and does not trap")
    func absurdByteCountDoesNotFit() {
        // The size reaching this guard can be a peer's declared `total_bytes`
        // clamped into `Int`, so the margin must not be added into an overflow.
        let staging = makeStaging(freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { staging.sweep() }
        #expect(!staging.hasCapacity(forByteCount: .max))
        #expect(!staging.hasCapacity(forByteCount: .max, margin: 1))
    }

    @Test("a crafted filename can't escape the generation directory")
    func sanitizesPathTraversal() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: "../../escape.png")
        let url = sink.url
        #expect(url.lastPathComponent == "escape.png")
        #expect(url.deletingLastPathComponent().lastPathComponent != "..")
    }

    @Test(
        "a dot-only filename falls back to a safe name",
        arguments: ["..", "."])
    func sanitizesDotOnlyNames(_ name: String) throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let sink = try staging.makeSink(generation: 1, filename: name)
        try sink.write(Data([1]))
        try sink.commit()
        #expect(sink.url.lastPathComponent == "clipboard-file")
        #expect(FileManager.default.fileExists(atPath: sink.url.path))
    }

    // MARK: - Directory / tree reservations (Phase 2)

    @Test("reserveDirectory creates an empty directory named exactly `name`")
    func reserveDirectoryKeepsName() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let dir = try staging.reserveDirectory(generation: 1, name: "MyFolder")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(dir.lastPathComponent == "MyFolder")
    }

    @Test("two same-named folders in one generation both keep the exact name")
    func reserveDirectoryNameSurvivesSameNamedSibling() throws {
        // One copy can carry two folders of the same name. Nesting each under a
        // fresh UUID parent keeps both names exact instead of degrading the
        // second to "MyFolder (2)".
        let staging = makeStaging()
        defer { staging.sweep() }

        let first = try staging.reserveDirectory(generation: 5, name: "MyFolder")
        let second = try staging.reserveDirectory(generation: 5, name: "MyFolder")
        #expect(first != second)
        #expect(first.lastPathComponent == "MyFolder")
        #expect(second.lastPathComponent == "MyFolder")
    }

    @Test("reserveDirectory sanitizes a path-traversal name")
    func reserveDirectorySanitizes() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let dir = try staging.reserveDirectory(generation: 1, name: "../../escape")
        #expect(dir.lastPathComponent == "escape")
        #expect(dir.deletingLastPathComponent().lastPathComponent != "..")
    }

    @Test("reserveScratchDirectory hands each caller its own empty directory in the generation")
    func reserveScratchDirectoryIsolatesCallers() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let first = try staging.reserveScratchDirectory(generation: 1)
        let second = try staging.reserveScratchDirectory(generation: 1)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
        // Two drops in one generation must not write into each other's directory.
        #expect(first != second)
        #expect(first.deletingLastPathComponent() == second.deletingLastPathComponent())
    }

    @Test("discardGeneration retires one generation early, leaving the rest of the window")
    func discardGenerationRetiresEarly() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        let first = try staging.reserveScratchDirectory(generation: 1)
        let second = try staging.reserveScratchDirectory(generation: 2)

        staging.discardGeneration(1)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        // Discarding a generation the window already evicted is a no-op, and the
        // number is not reused by the survivors.
        staging.discardGeneration(1)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("reserved trees and archives ride the generation window (3 newest survive)")
    func reservationsRideGenerationWindow() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        var dirs: [URL] = []
        for generation in 1...4 {
            dirs.append(try staging.reserveDirectory(generation: UInt64(generation), name: "g"))
        }
        // Generation 1's directory tree is evicted when generation 4 arrives.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }
}
