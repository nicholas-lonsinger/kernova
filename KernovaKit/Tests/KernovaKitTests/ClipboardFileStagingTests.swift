import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardFileStaging", .caseScoped)
struct ClipboardFileStagingTests {
    private let stagingRoot = TestStagingRoot()

    /// A fresh staging instance under this test's own process root.
    private func makeStaging(
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> ClipboardFileStaging {
        ClipboardFileStaging(
            label: "test-\(UUID().uuidString)", root: stagingRoot.root,
            freeSpaceProvider: freeSpaceProvider
        )
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
        #expect(urlB.lastPathComponent == "dup 2.txt")
        #expect(try Data(contentsOf: urlA) == Data("first".utf8))
        #expect(try Data(contentsOf: urlB) == Data("second".utf8))
    }

    @Test("a sink's name is sanitized and counts up Finder-style past every taken name")
    func sinkNamingCountsUpFinderStyle() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        func sinkName(_ filename: String) throws -> String {
            try staging.makeSink(generation: 1, filename: filename).commit().lastPathComponent
        }
        #expect(try sinkName("dup.txt") == "dup.txt")
        #expect(try sinkName("dup.txt") == "dup 2.txt")
        #expect(try sinkName("dup.txt") == "dup 3.txt")
        #expect(try sinkName("notes") == "notes")
        #expect(try sinkName("notes") == "notes 2")
        #expect(try sinkName("archive.tar.gz") == "archive.tar.gz")
        #expect(try sinkName("archive.tar.gz") == "archive.tar 2.gz")

        let escaped = try staging.makeSink(generation: 1, filename: "../escape.txt")
        let generationDir = try staging.makeSink(generation: 1, filename: "x.bin").url
            .deletingLastPathComponent()
        #expect(escaped.url.lastPathComponent == "escape.txt")
        #expect(escaped.url.deletingLastPathComponent() == generationDir)
    }

    @Test("same-label instances from different sessions own disjoint roots; one's sweep leaves the other's files")
    func sameLabelInstancesAreDisjoint() throws {
        // A VM restart mints a fresh staging instance under the same label; its
        // sweeps must never delete the previous session's files, which can still
        // back URLs on the pasteboard.
        let previousSession = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)
        let nextSession = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)

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
        let previousSession = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)
        let liveSession = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)
        let otherLabel = ClipboardFileStaging(label: "host-other", root: stagingRoot.root)

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

    @Test("reclaimSiblingRoots never reaches another process root's same-label staging")
    func reclaimSiblingRootsNeverCrossesProcessRoots() throws {
        let otherProcess = stagingRoot.makeSibling()
        let theirs = ClipboardFileStaging(label: "host-vm", root: otherProcess)
        let ours = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)

        let kept = try theirs.makeSink(generation: 1, filename: "kept.bin")
        try kept.commit()
        let own = try ours.makeSink(generation: 1, filename: "own.bin")
        try own.commit()

        ours.reclaimSiblingRoots()

        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        #expect(FileManager.default.fileExists(atPath: own.url.path))
    }

    @Test("the default free-space query answers before the label directory exists")
    func capacityIsKnownBeforeTheLabelExists() {
        let staging = ClipboardFileStaging(label: "host-vm", root: stagingRoot.root)
        #expect(staging.availableCapacity() != nil)
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
        #expect(unknownStaging.hasCapacity(forByteCount: Int.max - ClipboardFileStaging.freeSpaceMargin))
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

    // MARK: - Directory / tree reservations (Phase 2)

    @Test("reserved directories ride the generation window (3 newest survive)")
    func reservationsRideGenerationWindow() throws {
        let staging = makeStaging()
        defer { staging.sweep() }

        var dirs: [URL] = []
        for generation in 1...4 {
            dirs.append(try staging.reserveScratchDirectory(generation: UInt64(generation)))
        }
        // Generation 1's directory is evicted when generation 4 arrives.
        #expect(!FileManager.default.fileExists(atPath: dirs[0].path))
        #expect(FileManager.default.fileExists(atPath: dirs[1].path))
        #expect(FileManager.default.fileExists(atPath: dirs[3].path))
    }
}
